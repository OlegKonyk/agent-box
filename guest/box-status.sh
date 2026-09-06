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
# The `firewall` field is the MODE now: deny, observe, open or unknown. It used
# to be drop/open/unknown, read from the OUTPUT policy. The policy is still what
# is checked — a mode file saying `deny` on a box whose ruleset is not actually
# denying would be the worst of both — but the answer is reported in the same
# vocabulary the operator chose the box with.
#
# `unknown` whenever the two disagree or the ruleset cannot be read at all. This
# command must never report a mode it did not see evidence for.
FIREWALL="unknown"
# `-w`: a rebuild can hold the xtables lock for a stretch, and iptables 1.8
# without it exits non-zero rather than waiting — which would report `unknown`
# on a perfectly healthy box every time `status --watch` landed on a rebuild.
MODE_CLAIMED=""
[ -r /etc/agent-box/egress-mode ] \
    && MODE_CLAIMED=$(tr -d '[:space:]' < /etc/agent-box/egress-mode 2>/dev/null)
if POLICY=$(sudo -n iptables -w 5 -S 2>/dev/null | grep -- '-P OUTPUT'); then
    case "${MODE_CLAIMED}:${POLICY}" in
        deny:*DROP*)
            FIREWALL="deny" ;;
        observe:*DROP*)
            # Observe also runs OUTPUT DROP; what distinguishes it is that the
            # chain ends in ACCEPT after a LOG rather than in REJECT. Check the
            # thing that differs, not the thing that does not.
            if sudo -n iptables -w 5 -S AGENTBOX-OUT 2>/dev/null | grep -q -- '-j LOG --log-prefix'; then
                FIREWALL="observe"
            fi ;;
        open:*ACCEPT*)
            FIREWALL="open" ;;
        :*DROP*)
            # No mode file: an older box, or one whose /etc was not written.
            # The policy is denying, so say so in the old vocabulary rather
            # than inventing a mode nobody set.
            FIREWALL="deny" ;;
    esac
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
    --sessions "$SESSIONS"
