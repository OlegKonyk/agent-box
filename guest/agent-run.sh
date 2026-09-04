#!/bin/bash
#
# agent-box — run one headless Claude Code task against /work.
#
# Runs in the guest, as the unprivileged guest user. Invoked by
# `agentbox run <repo> <brief.md> [--model sonnet]`, which pipes the brief in
# on standard input.
#
# Usage: agent-run.sh --slug <name> [--model sonnet] [--brief <path>|-]
#
# The brief is read from standard input when --brief is omitted or is "-".
# This script never pushes anything, anywhere.

set -euo pipefail

WORK_DIR="${AGENT_BOX_WORK:-/work}"
TOKEN_FILE="${HOME}/.config/agent-box/token"

# Run logs live in the guest home, NOT on the host mount. The model's own output
# is untrusted text and /work is the work Mac's filesystem; a transcript written
# there would land on that disk and in its backups. Only a scrubbed summary
# crosses over.
GUEST_RUNS_DIR="${HOME}/.agent-box/runs"

# The native installer puts claude in ~/.local/bin, which a non-login shell
# does not pick up. `limactl shell <inst> -- agent-run.sh` is such a shell.
export PATH="${HOME}/.local/bin:${PATH}"

MODEL="sonnet"
SLUG=""
BRIEF_SRC="-"

die() { printf 'agent-run: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --model) MODEL="${2:?--model needs a value}"; shift 2 ;;
        --slug)  SLUG="${2:?--slug needs a value}"; shift 2 ;;
        --brief) BRIEF_SRC="${2:?--brief needs a value}"; shift 2 ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Preconditions. All of them, before anything is changed.
# ---------------------------------------------------------------------------

[ "$(id -u)" -ne 0 ] || die "refusing to run as root: Claude Code rejects --dangerously-skip-permissions for root, and the whole point of the guest user is that it is not root"

[ -d "$WORK_DIR" ] || die "${WORK_DIR} is not mounted"
git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "${WORK_DIR} is not a git repository"

[ -f "$TOKEN_FILE" ] || die "no token at ${TOKEN_FILE}. Run 'agentbox token <repo>' on the host first."
token_mode=$(stat -c '%a' "$TOKEN_FILE")
[ "$token_mode" = "600" ] || die "${TOKEN_FILE} has mode ${token_mode}; expected 600"

# An API key silently outranks the OAuth token, which would bill an API account
# instead of drawing on the subscription. Refuse rather than surprise.
[ -z "${ANTHROPIC_API_KEY:-}" ] || die "ANTHROPIC_API_KEY is set; it would override the subscription token. Unset it."
[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] || die "ANTHROPIC_AUTH_TOKEN is set; it would override the subscription token. Unset it."

if ! systemctl is-active --quiet agent-box-firewall.service; then
    die "the egress firewall is not active; refusing to run an agent with unrestricted network"
fi

command -v claude >/dev/null 2>&1 || die "claude is not on PATH"

# ---------------------------------------------------------------------------
# The brief
# ---------------------------------------------------------------------------

BRIEF_FILE=$(mktemp -t agent-box-brief.XXXXXX)
trap 'rm -f "$BRIEF_FILE"' EXIT

if [ "$BRIEF_SRC" = "-" ]; then
    cat > "$BRIEF_FILE"
else
    [ -f "$BRIEF_SRC" ] || die "brief not found: ${BRIEF_SRC}"
    cat "$BRIEF_SRC" > "$BRIEF_FILE"
fi
[ -s "$BRIEF_FILE" ] || die "the brief is empty"

[ -n "$SLUG" ] || SLUG="task"
SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')
[ -n "$SLUG" ] || SLUG="task"

# Seconds, not minutes: two runs of the same brief inside one minute would
# otherwise collide and the second `git checkout -b` would fail.
STAMP=$(date +%Y%m%d-%H%M%S)
BRANCH="agent/${SLUG}-${STAMP}"

# ---------------------------------------------------------------------------
# Bookkeeping stays out of the work repo's tracked files
# ---------------------------------------------------------------------------

GIT_DIR=$(cd "$WORK_DIR" && git rev-parse --git-dir)
case "$GIT_DIR" in /*) ;; *) GIT_DIR="${WORK_DIR}/${GIT_DIR}" ;; esac
mkdir -p "${GIT_DIR}/info"
touch "${GIT_DIR}/info/exclude"
grep -qxF '/.agent-box/' "${GIT_DIR}/info/exclude" || printf '/.agent-box/\n' >> "${GIT_DIR}/info/exclude"

mkdir -p "$GUEST_RUNS_DIR"
chmod 700 "$GUEST_RUNS_DIR"
RUN_LOG="${GUEST_RUNS_DIR}/${STAMP}.json"

SUMMARY_DIR="${WORK_DIR}/.agent-box"
mkdir -p "$SUMMARY_DIR"
SUMMARY_FILE="${SUMMARY_DIR}/last-run.txt"

# ---------------------------------------------------------------------------
# Branch, remembering where to go back to
# ---------------------------------------------------------------------------

ORIGINAL_REF=$(git -C "$WORK_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$WORK_DIR" rev-parse --short HEAD)
BRANCH_CREATED=0

restore_branch_if_untouched() {
    # Leaving the host's working copy parked on an empty agent branch is just
    # confusing when the user goes to review. Only restore when nothing was
    # modified — never throw work away.
    [ "$BRANCH_CREATED" -eq 1 ] || return 0
    if [ -n "$(git -C "$WORK_DIR" status --porcelain 2>/dev/null)" ]; then
        printf 'agent-run: leaving the work tree on %s; it has uncommitted changes\n' "$BRANCH"
        return 0
    fi
    if git -C "$WORK_DIR" checkout --quiet "$ORIGINAL_REF" 2>/dev/null; then
        git -C "$WORK_DIR" branch --quiet -D "$BRANCH" 2>/dev/null || true
        printf 'agent-run: the run produced no changes; returned the work tree to %s and removed %s\n' "$ORIGINAL_REF" "$BRANCH"
    else
        printf 'agent-run: could not return the work tree to %s; it is still on %s\n' "$ORIGINAL_REF" "$BRANCH"
    fi
}

git -C "$WORK_DIR" checkout -b "$BRANCH"
BRANCH_CREATED=1
printf 'agent-run: branch %s created from %s (%s)\n' "$BRANCH" "$ORIGINAL_REF" "$(git -C "$WORK_DIR" rev-parse --short HEAD)"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# Read the token without it ever appearing in argv, in a log, or on a terminal.
CLAUDE_CODE_OAUTH_TOKEN=$(cat "$TOKEN_FILE")
export CLAUDE_CODE_OAUTH_TOKEN

# Kept for the leak check below. Eight characters at each end is enough to
# recognise the credential without reconstituting it, and neither variable is
# ever printed.
TOK_HEAD="${CLAUDE_CODE_OAUTH_TOKEN:0:8}"
TOK_TAIL="${CLAUDE_CODE_OAUTH_TOKEN: -8}"

printf 'agent-run: model %s, brief %d bytes\n' "$MODEL" "$(wc -c < "$BRIEF_FILE")"

set +e
(
    cd "$WORK_DIR" || exit 1
    claude -p \
        --model "$MODEL" \
        --dangerously-skip-permissions \
        --output-format json \
        "$(cat "$BRIEF_FILE")"
) > "$RUN_LOG"
RUN_STATUS=$?
set -e

chmod 600 "$RUN_LOG"
unset CLAUDE_CODE_OAUTH_TOKEN

# ---------------------------------------------------------------------------
# Leak check
# ---------------------------------------------------------------------------
#
# The agent runs with --dangerously-skip-permissions, can read the token file,
# and can write anywhere under /work, which is the host's disk. That does not
# require malice: repository content is untrusted input to the model. So before
# anything is reported as successful, check the places the token would most
# plausibly turn up. A backstop, not a boundary — see docs/decisions.md.

leak_hit=0
check_stream_for_token() {
    local what="$1"
    if grep -qF -e "$TOK_HEAD" -e "$TOK_TAIL"; then
        printf 'agent-run: SECURITY: the token appears in %s\n' "$what" >&2
        leak_hit=1
    fi
}

# The summary is written first, so that it is one of the things checked: it is
# the one file this run puts on the host's disk.
CHANGED=$(git -C "$WORK_DIR" status --short 2>/dev/null || true)

{
    printf 'branch    : %s\n' "$BRANCH"
    printf 'started   : %s\n' "$ORIGINAL_REF"
    printf 'model     : %s\n' "$MODEL"
    printf 'exit code : %d\n' "$RUN_STATUS"
    printf 'files     : %s changed\n' "$(printf '%s' "$CHANGED" | grep -c . || true)"
    printf '\nThe full JSON transcript stays inside the VM, under ~/.agent-box/runs/.\n'
} > "$SUMMARY_FILE"

# Process substitution, NOT a pipe. `cmd | check_stream_for_token` runs the
# function in a subshell, so the `leak_hit=1` it sets is discarded when that
# subshell exits: the warning would print, the script would carry on, and the
# caller would see a successful run. These streams are exactly the ones that
# represent the token reaching the host's disk, so losing the flag defeats the
# entire check.
check_stream_for_token "the run log"        < "$RUN_LOG"
check_stream_for_token "the run summary"    < "$SUMMARY_FILE"
check_stream_for_token "git status output"  < <(git -C "$WORK_DIR" status --short 2>/dev/null)
check_stream_for_token "the unstaged diff"  < <(git -C "$WORK_DIR" diff 2>/dev/null)
check_stream_for_token "the staged diff"    < <(git -C "$WORK_DIR" diff --cached 2>/dev/null)

TOK_HEAD=""; TOK_TAIL=""
unset TOK_HEAD TOK_TAIL

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n----- agent-run summary -----\n'
printf 'branch    : %s\n' "$BRANCH"
printf 'exit code : %d\n' "$RUN_STATUS"
printf 'log       : %s (inside the VM only)\n' "$RUN_LOG"
printf 'summary   : %s\n' "$SUMMARY_FILE"
printf 'changes   :\n'
printf '%s\n' "$CHANGED"

if [ "$leak_hit" -eq 1 ]; then
    printf '\nSECURITY: the OAuth token was found in output that reaches the host.\n' >&2
    printf 'Rotate it now: revoke at claude.ai -> Settings -> Claude Code, then run claude setup-token again.\n' >&2
    exit 3
fi

if [ "$RUN_STATUS" -ne 0 ]; then
    restore_branch_if_untouched
fi

printf '\nNothing has been pushed. Review the branch on the host, then push it yourself.\n'
exit "$RUN_STATUS"
