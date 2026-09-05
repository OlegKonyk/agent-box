#!/bin/bash
#
# agent-box — prove the OAuth token actually authenticates.
#
# Runs in the guest, as the unprivileged guest user. Invoked by
# `agentbox verify-auth <repo>`.
#
# Nothing else in this VM exports CLAUDE_CODE_OAUTH_TOKEN into an interactive
# shell, so "run `agentbox shell` and then `claude -p ...`" does not work: the
# CLI finds no credential and asks the user to log in through a browser the VM
# does not have. This script is that test, done properly — the export and the
# call in one process. (`agentbox claude` is the other way to get an
# authenticated session, and it takes its preconditions from the same lib.sh.)
#
# Prints pass or fail and the model's reply. The token is never printed, and
# the CLI's own output is scrubbed of the token's head and tail before it is
# shown, because that output reaches the host terminal.

set -uo pipefail

MODEL="${1:-haiku}"

die() { printf 'verify-auth: FAIL — %s\n' "$*" >&2; exit 1; }

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

# `warn`: this command exists to diagnose a broken box, and refusing to
# diagnose because the box is broken helps nobody. agent-run and claude-session
# pass `die` here instead.
abx_assert_environment warn

# The same session-only plugin roots a real session gets. Verifying auth with a
# different plugin set than the one that will actually run would prove the
# wrong thing, and a hook that fails to load is worth seeing here first.
PLUGIN_ARGS=()
mapfile -t PLUGIN_ARGS < <(abx_plugin_dir_args)
abx_report_plugin_dirs "${PLUGIN_ARGS[@]}"

abx_export_token

printf 'verify-auth: asking %s for a one-word reply...\n' "$MODEL"

OUT=$(claude "${PLUGIN_ARGS[@]}" -p --model "$MODEL" 'reply with the single word OK' 2>&1)
RC=$?

abx_forget_token

# Everything this script prints goes to the host's terminal and its scrollback,
# which is the one channel the whole design exists to keep clean. The CLI's
# stderr is folded into OUT above, so nothing is printed before the token's
# recognisable head and tail have been removed from it.
SAFE_OUT=$(abx_scrub_token "$OUT")

if [ "$RC" -ne 0 ]; then
    printf 'verify-auth: FAIL — claude exited %d\n' "$RC" >&2
    # Only the first line: an auth error can be long, and the less of the CLI's
    # raw output that reaches this terminal the better.
    printf 'first line of the error: %s\n' "$(printf '%s\n' "$SAFE_OUT" | head -1)" >&2
    exit 1
fi

printf 'reply: %s\n' "$SAFE_OUT"

# Anchored: a bare `grep -qi ok` matches inside ordinary words, "token" and
# "broken" among them, so a refusal or a status message would be reported as a
# pass.
if printf '%s' "$SAFE_OUT" | grep -qiE '(^|[^a-z])ok([^a-z]|$)'; then
    printf 'verify-auth: PASS — the token authenticates and the model answered.\n'
    exit 0
fi

printf 'verify-auth: FAIL — the call succeeded but the reply was unexpected.\n' >&2
exit 1
