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
# call in one process.
#
# Prints pass or fail and the model's reply. The token is never printed, and
# the CLI's own output is scrubbed of the token's head and tail before it is
# shown, because that output reaches the host terminal.

set -uo pipefail

TOKEN_FILE="${HOME}/.config/agent-box/token"
MODEL="${1:-haiku}"

export PATH="${HOME}/.local/bin:${PATH}"

die() { printf 'verify-auth: FAIL — %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "must not run as root"
[ -f "$TOKEN_FILE" ] || die "no token at ${TOKEN_FILE}. Run 'agentbox token <repo>' on the host first."

token_mode=$(stat -c '%a' "$TOKEN_FILE")
[ "$token_mode" = "600" ] || die "${TOKEN_FILE} has mode ${token_mode}; expected 600"

[ -z "${ANTHROPIC_API_KEY:-}" ]   || die "ANTHROPIC_API_KEY is set; it would silently override the subscription token"
[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] || die "ANTHROPIC_AUTH_TOKEN is set; it would silently override the subscription token"

command -v claude >/dev/null 2>&1 || die "claude is not on PATH"

if ! systemctl is-active --quiet agent-box-firewall.service; then
    printf 'verify-auth: WARNING — the egress firewall is not active\n' >&2
fi

CLAUDE_CODE_OAUTH_TOKEN=$(cat "$TOKEN_FILE")
export CLAUDE_CODE_OAUTH_TOKEN

# Everything this script prints goes to the host's terminal and its scrollback,
# which is the one channel the whole design exists to keep clean. The CLI's
# stderr is folded into OUT below, so before anything is printed the token's
# recognisable head and tail are removed from it. Neither variable is printed.
TOK_HEAD="${CLAUDE_CODE_OAUTH_TOKEN:0:8}"
TOK_TAIL="${CLAUDE_CODE_OAUTH_TOKEN: -8}"

printf 'verify-auth: asking %s for a one-word reply...\n' "$MODEL"

OUT=$(claude -p --model "$MODEL" 'reply with the single word OK' 2>&1)
RC=$?

unset CLAUDE_CODE_OAUTH_TOKEN

# Bash literal substitution, not sed. Building a sed expression out of token
# text treats it as a regex AND as a delimiter: a single slash in the fragment
# makes sed abort with a message quoting the offending expression, which prints
# the fragment unredacted, empties SAFE_OUT, loses the diagnostic, and turns a
# successful authentication into a FAIL. Quoting the pattern inside
# ${var//pat/rep} makes it literal, needs no escaping, and costs no subprocess.
SAFE_OUT="${OUT//"$TOK_HEAD"/<redacted>}"
SAFE_OUT="${SAFE_OUT//"$TOK_TAIL"/<redacted>}"

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
