#!/bin/bash
#
# agent-box — one JSON line describing this box, for `agentbox status`.
#
# Runs in the guest, as the unprivileged guest user. ONE invocation per running
# box per refresh: `agentbox status --watch` redraws every few seconds, and a
# status display that costs three `limactl shell` round trips per box is a
# status display nobody leaves running.
#
# It prints the object the host wraps in `name`, `instance` and `repo` — the
# three things the host already knows and the guest has no business being told.
# Everything printed has been through the scrub in guest/run-format.py, which
# is why the assembly happens here rather than on the host: the unscrubbed
# bytes must not cross the terminal boundary in the first place.

set -uo pipefail

die() { printf 'box-status: %s\n' "$*" >&2; exit 1; }

# --text prints the same facts as one human line instead of one JSON object.
# Both come out of the same place for the same reason: whichever the host asks
# for, the scrub has already happened by the time it crosses.
MODE="--box-json"
case "${1:-}" in
    --text) MODE="--box-text" ;;
    "")     ;;
    *)      die "usage: box-status.sh [--text]" ;;
esac

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

# --- the CLI's version, from a cache -------------------------------------
#
# `status --watch` calls this every few seconds. Spawning the CLI each time to
# ask its version costs a process in the guest per refresh, competing with the
# agent this is supposed to be observing. The version only changes when
# `agentbox update` changes it, and that command removes this file.
CLAUDE_VERSION=""
VERSION_CACHE="${ABX_STATE_DIR}/claude-version"
if [ -r "$VERSION_CACHE" ]; then
    CLAUDE_VERSION=$(head -1 "$VERSION_CACHE" 2>/dev/null)
fi
if [ -z "$CLAUDE_VERSION" ] && command -v claude >/dev/null 2>&1; then
    CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
    if [ -n "$CLAUDE_VERSION" ]; then
        abx_private_dir "$ABX_STATE_DIR" 2>/dev/null || true
        printf '%s\n' "$CLAUDE_VERSION" > "$VERSION_CACHE" 2>/dev/null || true
    fi
fi

# --- the egress mode --------------------------------------------------------
#
# The `firewall` field is the MODE now: deny, observe, open or unknown. It is
# derived from the LIVE RULESET by guest/egress-mode.sh, never from the mode
# file — a file is what somebody asked for, and reporting it as fact is how a
# box that permits everything comes to be described as denying.
#
# When the file and the ruleset disagree, the answer is `unknown` and
# `firewall_detail` says what both of them said. Unknown is the honest answer
# to "which of these two do you believe", and picking one silently is not.
FIREWALL="unknown"
FIREWALL_DETAIL=""
if MODE_LINE=$("${ABX_LIB_DIR}/egress-mode.sh" 2>/dev/null); then
    _live=$(printf '%s' "$MODE_LINE" | sed -n 's/.*live=\([a-z]*\).*/\1/p')
    FIREWALL_DETAIL=$(printf '%s' "$MODE_LINE" | sed -n 's/.*detail=//p')
    if [ -n "$FIREWALL_DETAIL" ]; then
        FIREWALL="unknown"
    else
        FIREWALL="${_live:-unknown}"
    fi
fi

# --- orphaned runs --------------------------------------------------------
#
# A run whose process died without its EXIT trap says `running` for ever. This
# is one of the three places that reconciles it, and the cheapest: `status` is
# the command someone runs to find out what is going on.
"${ABX_LIB_DIR}/run-ctl.sh" reconcile 2>/dev/null || true

# --- tmux sessions ---------------------------------------------------------
#
# Already scrubbed and control-stripped by run-format.py, and built with jq
# before that, so what arrives here is well-formed JSON. An empty string is
# passed straight through rather than being turned into `[]`: run-format.py
# reports an unreadable list as null, which a consumer can tell apart from a
# box that genuinely has no sessions.
SESSIONS='[]'
if command -v tmux >/dev/null 2>&1; then
    SESSIONS=$("${ABX_LIB_DIR}/run-ctl.sh" sessions --json 2>/dev/null) || SESSIONS=''
fi

# --- the run, the totals, and the scrub ------------------------------------
exec python3 "${ABX_LIB_DIR}/run-format.py" "$MODE" \
    --claude-version "$CLAUDE_VERSION" \
    --firewall "$FIREWALL" \
    --firewall-detail "$FIREWALL_DETAIL" \
    --sessions "$SESSIONS"
