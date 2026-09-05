#!/bin/bash
#
# agent-box — run one headless Claude Code task against /work.
#
# Runs in the guest, as the unprivileged guest user. Invoked by
# `agentbox run <repo> <brief.md> [...]`, normally inside a tmux session so the
# run outlives the shell that started it.
#
# Usage: agent-run.sh [--runid ID] [--slug NAME] [--model M] [--brief PATH|-]
#                     [--session TMUX] [--max-turns N] [--max-budget-usd X]
#
# The brief is read from standard input when --brief is omitted or is "-".
# This script never pushes anything, anywhere.
#
# Everything it records lives in ~/.agent-box/runs/<runid>/, in the guest home
# and NOT on the host mount: the model's own output is untrusted text and /work
# is the host's filesystem, so a transcript written there would land on that
# disk and in its backups. Only the scrubbed summary crosses.

set -uo pipefail
set -e

# Every timestamp this project writes is UTC, so that two sensors read by
# different processes merge in the right order. Set for the whole script,
# because bash's printf %()T and date(1) both read it.
export TZ=UTC

WORK_DIR="${AGENT_BOX_WORK:-/work}"

MODEL="sonnet"
SLUG=""
BRIEF_SRC="-"
RUNID=""
TMUX_SESSION=""
MAX_TURNS=""
MAX_BUDGET=""
INTERRUPTED=0

die() { printf 'agent-run: %s\n' "$*" >&2; exit 1; }

# PATH, the token file, the run-directory helpers, and the preconditions that
# every path exporting the token has to satisfy. Shared with verify-auth.sh and
# claude-session.sh so the three cannot drift apart into being differently
# strict.
ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        --model)          MODEL="${2:?--model needs a value}"; shift 2 ;;
        --slug)           SLUG="${2:?--slug needs a value}"; shift 2 ;;
        --brief)          BRIEF_SRC="${2:?--brief needs a value}"; shift 2 ;;
        --runid)          RUNID="${2:?--runid needs a value}"; shift 2 ;;
        --session)        TMUX_SESSION="${2:?--session needs a value}"; shift 2 ;;
        --max-turns)      MAX_TURNS="${2:?--max-turns needs a value}"; shift 2 ;;
        --max-budget-usd) MAX_BUDGET="${2:?--max-budget-usd needs a value}"; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$SLUG" ] || SLUG="task"
SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')
[ -n "$SLUG" ] || SLUG="task"

# Seconds, not minutes: two runs of the same brief inside one minute would
# otherwise collide, on the branch name and on the run directory alike.
[ -n "$RUNID" ] || RUNID=$(date -u +%Y%m%d-%H%M%S)
BRANCH="agent/${SLUG}-${RUNID}"

# ---------------------------------------------------------------------------
# The run directory, BEFORE anything can refuse
# ---------------------------------------------------------------------------
#
# A run that dies in its preconditions is the one an operator most needs to
# read back, and a detached run has no terminal for it to have been printed on.
# So the directory, the status file and the console log all exist before the
# first thing that can fail.

# Before the first directory, not after: mkdir -p creates intermediate
# directories under the inherited umask, so setting it later leaves the state
# root group- and world-readable on a box where it did not already exist.
umask 077

RUN_DIR=$(abx_run_dir "$RUNID")
abx_private_dir "$ABX_RUNS_DIR"
abx_private_dir "$RUN_DIR"

# The trap goes on BEFORE the status says `running`, and before the redirection
# that everything after it depends on. A failure in between — a full disk on the
# first `: >`, an fd that will not open — would otherwise exit under `set -e`
# with the status stuck at `running` and no meta.json, which makes the run
# invisible to `runs`, `stop-run` and `status` all at once: there would be no
# command left that could clear it.
TEE_PID=""
BRIEF_FILE=""
CONSOLE_REDIRECTED=0

# shellcheck disable=SC2329  # invoked by the EXIT trap below.
finish() {
    local rc=$?
    trap - EXIT
    [ -z "${BRIEF_FILE:-}" ] || rm -f "$BRIEF_FILE"
    # Close the pipe first, then wait, then write the status. The status file
    # is the signal every reader watches for, and writing it before the console
    # has drained is how `agentbox logs -f` comes back missing the last thing
    # that was printed.
    if [ "${CONSOLE_REDIRECTED:-0}" -eq 1 ]; then
        exec 1>&3 2>&4
        if [ -n "${TEE_PID:-}" ]; then
            # Bounded, because the reader only sees EOF when EVERY write end
            # closes — and a child the CLI leaves behind inherits this script's
            # stderr, so it holds one. Waiting for that would keep the run at
            # `running` for as long as the orphan lives. Five seconds is far
            # more than draining what is already buffered takes.
            local drained=0
            while [ "$drained" -lt 5 ]; do
                kill -0 "$TEE_PID" 2>/dev/null || break
                sleep 1
                drained=$((drained + 1))
            done
            kill "$TEE_PID" 2>/dev/null || true
            wait "$TEE_PID" 2>/dev/null || true
        else
            sleep 1
        fi
    fi
    # The exit code the run really finished with, always. The stop, when there
    # was one, is recorded ALONGSIDE it rather than in its place.
    #
    # Writing `exit:stopped` over the code destroyed information, and in one
    # case destroyed a guarantee: exit 3 is what the leak check writes when it
    # found the token in output that reaches the host, and `logs` refuses to
    # print a run whose status is exit:3. A stop that landed on a leaking run
    # replaced that 3 with `stopped`, the refusal never fired, and the very
    # credential the exit-3 path exists to withhold was printed.
    #
    # So: 3 is never rewritten by anything, and neither is any other code. The
    # marker is what says a stop happened; run-format.py derives the state from
    # the two together.
    if [ -e "${RUN_DIR}/stop-requested" ] && ! run_ended_cleanly "$rc"; then
        printf '%s\n' "$(abx_now_iso)" > "${RUN_DIR}/stopped"
        chmod 600 "${RUN_DIR}/stopped" 2>/dev/null || true
    fi
    abx_status_write "$RUN_DIR" "exit:${rc}"
    rm -f "${RUN_DIR}/pid" "${RUN_DIR}/claude-pid"
    exit "$rc"
}

# Clean means: the process exited 0, the CLI did not flag an error, and its
# result was `success`. Any field that was never read is not evidence either
# way, so an unset one does not make a run dirty on its own.
# shellcheck disable=SC2329  # called from the EXIT trap.
run_ended_cleanly() {
    [ "${1:-1}" -eq 0 ] || return 1
    [ "${RUN_IS_ERROR:-}" != "true" ] || return 1
    case "${RUN_SUBTYPE:-}" in
        ''|-|success) return 0 ;;
        *) return 1 ;;
    esac
}
trap finish EXIT

abx_status_write "$RUN_DIR" "running"
# The pid, so that a run whose process died without its trap can be told apart
# from one that is still going. See `run-ctl.sh reconcile`.
printf '%s\n' "$$" > "${RUN_DIR}/pid"

EVENTS_FILE="${RUN_DIR}/events.jsonl"
HOOKS_FILE="${RUN_DIR}/hooks.jsonl"
CONSOLE_FILE="${RUN_DIR}/console.log"
RUN_SUMMARY="${RUN_DIR}/summary.txt"
STARTED_AT=$(abx_now_iso)
: > "$EVENTS_FILE"
: > "$CONSOLE_FILE"
: > "$HOOKS_FILE"

# Hook events land in this run's directory. hook-event.sh does nothing at all
# when this is unset, which is what keeps a session launched some other way
# from writing into a directory nobody is watching.
export AGENT_BOX_EVENTS_DIR="$RUN_DIR"

# Everything this script prints goes to two places: the terminal, unchanged, so
# that invoking it directly still behaves as it always did; and console.log,
# one ISO timestamp per line, so a detached run can be read back afterwards and
# merged with the other two sensors in the right order.
console_tee() {
    local line
    while IFS= read -r line; do
        printf '%s\n' "$line" >&3
        printf '%(%Y-%m-%dT%H:%M:%SZ)T %s\n' -1 "$line" >> "$CONSOLE_FILE"
    done
    # A last line with no trailing newline would otherwise be dropped.
    if [ -n "${line:-}" ]; then
        printf '%s\n' "$line" >&3
        printf '%(%Y-%m-%dT%H:%M:%SZ)T %s\n' -1 "$line" >> "$CONSOLE_FILE"
    fi
}

exec 3>&1 4>&2
exec > >(console_tee) 2>&1
TEE_PID=$!
CONSOLE_REDIRECTED=1

# Not fatal, and not ignored either. `agentbox stop-run` sends this; letting it
# fall through to bash's default would kill the script between the model
# stopping and the summary being written, which is exactly the run whose state
# someone wants to see.
#
# It also forwards. A SIGINT that reaches this script and stops here achieves
# nothing: the CLI keeps running, keeps spending, and — once the session is
# closed — keeps running orphaned in its own process group while the run is
# recorded as stopped. So the signal is passed on to the CLI's process group,
# and if the CLI has not started yet, the flag makes sure it never does.
# shellcheck disable=SC2329  # invoked by the INT trap below.
on_int() {
    INTERRUPTED=1
    [ -n "${CLAUDE_PID:-}" ] || return 0
    kill -INT -"$CLAUDE_PID" 2>/dev/null || kill -INT "$CLAUDE_PID" 2>/dev/null || true
}
trap on_int INT

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1 || true)

write_meta() {
    local branch="$1"
    local tmp="${RUN_DIR}/meta.json.tmp"
    jq -n \
        --arg runid      "$RUNID" \
        --arg model      "$MODEL" \
        --arg branch     "$branch" \
        --arg brief      "$(basename -- "$BRIEF_SRC")" \
        --arg started_at "$STARTED_AT" \
        --arg tmux       "$TMUX_SESSION" \
        --arg version    "$CLAUDE_VERSION" \
        --arg turns      "$MAX_TURNS" \
        --arg budget     "$MAX_BUDGET" \
        '{runid: $runid,
          model: $model,
          branch: (if $branch == "" then null else $branch end),
          brief: (if $brief == "-" then "(stdin)" else $brief end),
          started_at: $started_at,
          tmux: (if $tmux == "" then null else $tmux end),
          max_turns: (if $turns == "" then null else ($turns | tonumber?) end),
          max_budget_usd: (if $budget == "" then null else ($budget | tonumber?) end),
          claude_version: (if $version == "" then null else $version end)}' \
        > "$tmp" 2>/dev/null && mv -f "$tmp" "${RUN_DIR}/meta.json"
    chmod 600 "${RUN_DIR}/meta.json" 2>/dev/null || true
}
write_meta ""

printf 'agent-run: run %s (%s)\n' "$RUNID" "${TMUX_SESSION:-no tmux session}"

# ---------------------------------------------------------------------------
# Preconditions. All of them, before anything is changed.
# ---------------------------------------------------------------------------

# Not root, a 0600 token, no API key outranking it, claude on PATH, and the
# firewall up — `die`, not `warn`: this turns an agent loose, and an agent with
# unrestricted egress is the thing the VM exists to prevent.
abx_assert_environment die

[ -d "$WORK_DIR" ] || die "${WORK_DIR} is not mounted"
git -C "$WORK_DIR" rev-parse --git-dir >/dev/null 2>&1 || die "${WORK_DIR} is not a git repository"

# Session-only plugin roots from the read-only host config mount. Read before
# anything is changed, so a malformed one fails here rather than mid-run.
PLUGIN_ARGS=()
mapfile -t PLUGIN_ARGS < <(abx_plugin_dir_args)

# The hooks block, merged into whatever settings the operator already has.
SETTINGS_ARGS=()
mapfile -t SETTINGS_ARGS < <(abx_hook_settings_args)
if [ "${#SETTINGS_ARGS[@]}" -eq 0 ]; then
    printf 'agent-run: NOTE: %s is missing; this run records no hook events\n' "$ABX_HOOK_SETTINGS"
fi

# ---------------------------------------------------------------------------
# The brief
# ---------------------------------------------------------------------------

BRIEF_FILE=$(mktemp -t agent-box-brief.XXXXXX)

if [ "$BRIEF_SRC" = "-" ]; then
    cat > "$BRIEF_FILE"
else
    [ -f "$BRIEF_SRC" ] || die "brief not found: ${BRIEF_SRC}"
    cat "$BRIEF_SRC" > "$BRIEF_FILE"
fi
[ -s "$BRIEF_FILE" ] || die "the brief is empty"

# ---------------------------------------------------------------------------
# Bookkeeping stays out of the work repo's tracked files
# ---------------------------------------------------------------------------

GIT_DIR=$(cd "$WORK_DIR" && git rev-parse --git-dir)
case "$GIT_DIR" in /*) ;; *) GIT_DIR="${WORK_DIR}/${GIT_DIR}" ;; esac
mkdir -p "${GIT_DIR}/info"
touch "${GIT_DIR}/info/exclude"
grep -qxF '/.agent-box/' "${GIT_DIR}/info/exclude" || printf '/.agent-box/\n' >> "${GIT_DIR}/info/exclude"

SUMMARY_DIR="${WORK_DIR}/.agent-box"
mkdir -p "$SUMMARY_DIR"
SUMMARY_FILE="${SUMMARY_DIR}/last-run.txt"

# ---------------------------------------------------------------------------
# Branch, remembering where to go back to
# ---------------------------------------------------------------------------

ORIGINAL_REF=$(git -C "$WORK_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$WORK_DIR" rev-parse --short HEAD)
BRANCH_CREATED=0

# Leaving the host's working copy parked on an empty agent branch is confusing
# when the operator goes to review. Removing a branch that has work on it is
# very much worse, and a clean tree does not mean an empty branch: a brief that
# says "commit each fix" produces exactly a clean tree with three commits on it,
# and `git branch -D` does not refuse an unmerged branch.
#
# So three conditions, all of them: the run ended on its own, the branch has no
# commits beyond where it started, and the tree is clean. An interrupted run is
# never restored at all — `stop-run` promises in three places that nothing is
# reverted, and this is the code that has to make that true.
restore_branch_if_untouched() {
    [ "$BRANCH_CREATED" -eq 1 ] || return 0

    if [ "$INTERRUPTED" -eq 1 ] || [ "$RUN_STATUS" -eq 130 ]; then
        printf 'agent-run: interrupted; leaving the work tree on %s exactly as it is\n' "$BRANCH"
        return 0
    fi

    local ahead
    ahead=$(git -C "$WORK_DIR" rev-list --count "${ORIGINAL_REF}..HEAD" 2>/dev/null) || ahead=""
    case "$ahead" in
        ''|*[!0-9]*)
            printf 'agent-run: cannot tell whether %s has commits on it; leaving it alone\n' "$BRANCH"
            return 0 ;;
        0) ;;
        *)
            printf 'agent-run: leaving the work tree on %s; it has %s commit(s) on it\n' "$BRANCH" "$ahead"
            return 0 ;;
    esac

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
write_meta "$BRANCH"
printf 'agent-run: branch %s created from %s (%s)\n' "$BRANCH" "$ORIGINAL_REF" "$(git -C "$WORK_DIR" rev-parse --short HEAD)"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# Read the token without it ever appearing in argv, in a log, or on a terminal,
# and keep its head and tail for the leak check below.
abx_export_token

abx_report_plugin_dirs "${PLUGIN_ARGS[@]}"
printf 'agent-run: model %s, brief %d bytes\n' "$MODEL" "$(wc -c < "$BRIEF_FILE")"

# stream-json rather than json: it is the sensor the whole watch-and-steer
# design reads, and it arrives line by line while the run is still going rather
# than as one object at the end. --verbose is what makes the CLI emit the
# per-event stream at all, and --include-hook-events folds the hook lifecycle
# into it. --include-partial-messages is deliberately NOT used: token deltas
# would multiply the file size for nothing a log line can show.
CLAUDE_ARGS=(-p
    --model "$MODEL"
    --dangerously-skip-permissions
    --output-format stream-json
    --verbose)

if abx_claude_supports_flag '--include-hook-events'; then
    CLAUDE_ARGS+=(--include-hook-events)
else
    printf 'agent-run: NOTE: this CLI has no --include-hook-events; hooks.jsonl still records them\n'
fi

# Asked for, not assumed. A cap the installed CLI does not know is an "unknown
# option" that kills the run after the branch has already been made, which is a
# worse outcome than an uncapped run that says it is uncapped.
if [ -n "$MAX_BUDGET" ]; then
    if abx_claude_supports_flag '--max-budget-usd'; then
        CLAUDE_ARGS+=(--max-budget-usd "$MAX_BUDGET")
    else
        printf 'agent-run: NOTE: this CLI has no --max-budget-usd; the cap was NOT applied\n'
    fi
fi

if [ -n "$MAX_TURNS" ]; then
    if abx_claude_supports_flag '--max-turns'; then
        CLAUDE_ARGS+=(--max-turns "$MAX_TURNS")
    else
        printf 'agent-run: NOTE: this CLI has no --max-turns; the cap was NOT applied\n'
    fi
fi

# The CLI's own pid, recorded, so that `stop-run` can interrupt the CLI and
# nothing else.
#
# It used to signal every process under the tmux pane. Two of those are not the
# CLI: this script, and the console tee reading the other end of its stdout.
# Killing the tee left this script writing into a pipe with no reader, so its
# next line raised SIGPIPE and it died without its EXIT trap — no summary, no
# status of its own, and the run recorded by the stopper as a guess. That is
# the second half of issue #14.
#
# `exec` inside the subshell, so the recorded pid IS the CLI rather than a
# shell that happens to be its parent. `set -m` for the launch, so the CLI gets
# its own process group and a DEFAULT SIGINT disposition: a background command
# in a shell without job control has SIGINT set to ignore, and a stop that the
# CLI cannot receive is not a stop.
set +e
if [ "$INTERRUPTED" -eq 1 ] || [ -e "${RUN_DIR}/stop-requested" ]; then
    # A stop arrived while this run was still in its preconditions. Starting
    # the CLI now would spend the subscription on work nobody is waiting for,
    # and would leave it running after the stop had been reported.
    printf 'agent-run: a stop was requested before the CLI started; not launching it\n'
    INTERRUPTED=1
    RUN_STATUS=130
else
    set -m
    (
        cd "$WORK_DIR" || exit 1
        exec claude "${PLUGIN_ARGS[@]}" "${SETTINGS_ARGS[@]}" "${CLAUDE_ARGS[@]}" \
            "$(cat "$BRIEF_FILE")"
    ) > "$EVENTS_FILE" &
    CLAUDE_PID=$!
    set +m
    printf '%s\n' "$CLAUDE_PID" > "${RUN_DIR}/claude-pid"

    # In a loop, because a trapped signal makes `wait` return early with 128+n
    # while the CLI is still very much alive. Taking that as the exit status
    # meant tearing down a running run: removing its pid file, parsing a
    # half-written event stream, and writing a summary for something still
    # going. The loop keeps waiting until the process is actually reaped, and
    # the last `wait` is the one that carries its real status.
    # Bounded, and it stops on 127. `wait` returns 127 immediately, without
    # blocking, for a pid this shell does not own — which is what the CLI's pid
    # becomes the moment it is reaped and the number is reused by something
    # else on the box. `kill -0` would then keep succeeding against the
    # stranger, and the loop would spin at a full core with the run stuck at
    # `running` and its exit trap never reached.
    REAPS=0
    RUN_STATUS=0
    while :; do
        wait "$CLAUDE_PID"
        WAIT_RC=$?
        # 127 means this shell does not own that pid — which is what the CLI's
        # pid becomes once it has been reaped and the number is reused by
        # something else on the box. Break WITHOUT taking 127 as the run's
        # status: the last real wait already gave us that.
        [ "$WAIT_RC" -ne 127 ] || break
        RUN_STATUS=$WAIT_RC
        kill -0 "$CLAUDE_PID" 2>/dev/null || break
        REAPS=$((REAPS + 1))
        if [ "$REAPS" -ge 100 ]; then
            printf 'agent-run: gave up waiting for the CLI to be reaped after %s interrupted waits\n' "$REAPS"
            break
        fi
    done
    rm -f "${RUN_DIR}/claude-pid"
    CLAUDE_PID=""
fi
set -e

chmod 600 "$EVENTS_FILE"
abx_forget_token

# ---------------------------------------------------------------------------
# What the run cost, from the stream's own last word
# ---------------------------------------------------------------------------
#
# The `result` event is the CLI's own summary: turns, cost, wall time, and
# whether it considered itself to have failed. Read with `fromjson?` so a
# truncated last line — a run killed mid-write — is skipped rather than turned
# into a jq error on the way to reporting the failure.

RESULT_JSON=$(jq -c -R 'fromjson? | select(.type == "result")' "$EVENTS_FILE" 2>/dev/null | tail -1)

result_field() {
    local key="$1" value=""
    [ -n "$RESULT_JSON" ] || { printf -- '-'; return 0; }
    # `has` rather than `//`: jq's alternative operator treats `false` as
    # absent, so `is_error: false` would come back as "-" — the one value a
    # reader most wants to be able to trust.
    value=$(printf '%s' "$RESULT_JSON" \
        | jq -r --arg k "$key" 'if has($k) and .[$k] != null then .[$k] else empty end' 2>/dev/null \
        | head -1)
    [ -n "$value" ] || value="-"
    printf '%s' "$value"
}

RUN_TURNS=$(result_field num_turns)
RUN_COST=$(result_field total_cost_usd)
RUN_SUBTYPE=$(result_field subtype)
# Both, because they disagree: an authentication failure comes back with
# subtype `success` and is_error true, and a summary that reported only the
# first would call a run that never reached the model a success.
RUN_IS_ERROR=$(result_field is_error)

# ---------------------------------------------------------------------------
# What the run's outcome actually was
# ---------------------------------------------------------------------------
#
# Claude Code 2.1.261 in `-p` mode exits 0 when it is interrupted, and says so
# only in the result event: `subtype: error_during_execution`, `is_error: true`.
# Trusting the exit status alone recorded those runs as `done` with exit 0 —
# issue #14, seen on a real box. The result event is the CLI's own verdict on
# its own run, and it outranks a process exit status that is not telling us
# anything.
#
# A missing result event counts as a failure too: with --output-format
# stream-json the CLI always emits one, so its absence means the stream was cut
# off, and a cut-off run is not a successful run.
if [ "$RUN_STATUS" -eq 0 ]; then
    if [ "$RUN_IS_ERROR" = "true" ]; then
        printf 'agent-run: the CLI exited 0 but its result says is_error=true; recording this run as failed\n'
        RUN_STATUS=1
    elif [ "$RUN_SUBTYPE" != "success" ]; then
        printf 'agent-run: the CLI exited 0 but its result was %s, not success; recording this run as failed\n' \
            "$RUN_SUBTYPE"
        RUN_STATUS=1
    fi
fi

# ---------------------------------------------------------------------------
# Was a stop asked for?
# ---------------------------------------------------------------------------
#
# `run-ctl.sh stop` writes this file before it sends a signal, so the run finds
# out from the run directory rather than the stopper having to infer what
# happened from the outside. The stopper cannot tell an interrupted run from a
# run that happened to finish in the same second; the run can.
if [ -e "${RUN_DIR}/stop-requested" ]; then
    INTERRUPTED=1
    printf 'agent-run: a stop was requested for this run\n'
fi

# ---------------------------------------------------------------------------
# Leak check
# ---------------------------------------------------------------------------
#
# The agent runs with --dangerously-skip-permissions, can read the token file,
# and can write anywhere under /work, which is the host's disk. That does not
# require malice: repository content is untrusted input to the model. So before
# anything is reported as successful, check the places the token would most
# plausibly turn up. A backstop, not a boundary — see docs/decisions.md.
#
# hooks.jsonl and console.log are on the list because both carry text the model
# produced and both are printed to the host's terminal by `agentbox logs`.

leak_hit=0
check_stream_for_token() {
    local what="$1"
    if grep -qF -e "$ABX_TOK_HEAD" -e "$ABX_TOK_TAIL"; then
        printf 'agent-run: SECURITY: the token appears in %s\n' "$what" >&2
        leak_hit=1
    fi
}

# The summary is written first, so that it is one of the things checked: it is
# the one file this run puts on the host's disk.
CHANGED=$(git -C "$WORK_DIR" status --short 2>/dev/null || true)
FILES_CHANGED=$(printf '%s' "$CHANGED" | grep -c . || true)

# The same word `runs` and `status --json` will use, so that the summary a
# person reads and the record a program reads cannot disagree.
if [ "$INTERRUPTED" -eq 1 ] && ! run_ended_cleanly "$RUN_STATUS"; then
    RUN_STATE="stopped"
elif [ "$RUN_STATUS" -eq 0 ]; then
    RUN_STATE="done"
else
    RUN_STATE="failed"
fi

{
    printf 'runid     : %s\n' "$RUNID"
    printf 'branch    : %s\n' "$BRANCH"
    printf 'started   : %s\n' "$ORIGINAL_REF"
    printf 'model     : %s\n' "$MODEL"
    printf 'state     : %s\n' "$RUN_STATE"
    printf 'exit code : %d\n' "$RUN_STATUS"
    printf 'result    : %s\n' "$RUN_SUBTYPE"
    printf 'is_error  : %s\n' "$RUN_IS_ERROR"
    printf 'turns     : %s\n' "$RUN_TURNS"
    printf 'cost usd  : %s\n' "$RUN_COST"
    printf 'files     : %s changed\n' "$FILES_CHANGED"
    if [ "$RUN_STATE" = "stopped" ]; then
        printf 'note      : interrupted. Nothing was reverted: the work tree is still on\n'
        printf '            %s, with whatever the run had done to it.\n' "$BRANCH"
    fi
    printf '\nThe full event stream stays inside the VM, under ~/.agent-box/runs/%s/.\n' "$RUNID"
} > "$SUMMARY_FILE"
cp -f "$SUMMARY_FILE" "$RUN_SUMMARY" 2>/dev/null || true
chmod 600 "$RUN_SUMMARY" 2>/dev/null || true

# Process substitution, NOT a pipe. `cmd | check_stream_for_token` runs the
# function in a subshell, so the `leak_hit=1` it sets is discarded when that
# subshell exits: the warning would print, the script would carry on, and the
# caller would see a successful run. These streams are exactly the ones that
# represent the token reaching the host's disk or the host's terminal, so
# losing the flag defeats the entire check.
check_stream_for_token "the event stream"   < "$EVENTS_FILE"
check_stream_for_token "the hook log"       < "$HOOKS_FILE"
check_stream_for_token "the run console"    < "$CONSOLE_FILE"
check_stream_for_token "the run summary"    < "$SUMMARY_FILE"
check_stream_for_token "git status output"  < <(git -C "$WORK_DIR" status --short 2>/dev/null)
check_stream_for_token "the unstaged diff"  < <(git -C "$WORK_DIR" diff 2>/dev/null)
check_stream_for_token "the staged diff"    < <(git -C "$WORK_DIR" diff --cached 2>/dev/null)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

# Through the scrubber, and only now — after the leak check has read the raw
# streams. This block is what `agentbox attach <repo> <runid>` draws on the
# host terminal, and `git status --short` below lists file names the model
# chose. A token in one of those names would reach the pane before the check
# below has said a word about it.
printf '\n----- agent-run summary -----\n'
printf 'runid     : %s\n' "$(abx_scrub_token "$RUNID")"
printf 'branch    : %s\n' "$(abx_scrub_token "$BRANCH")"
printf 'state     : %s\n' "$RUN_STATE"
printf 'exit code : %d\n' "$RUN_STATUS"
printf 'turns     : %s\n' "$(abx_scrub_token "$RUN_TURNS")"
printf 'cost usd  : %s\n' "$(abx_scrub_token "$RUN_COST")"
printf 'events    : %s (inside the VM only)\n' "$EVENTS_FILE"
printf 'summary   : %s\n' "$SUMMARY_FILE"
printf 'changes   :\n'
printf '%s\n' "$(abx_scrub_token "$CHANGED")"

ABX_TOK_HEAD=""; ABX_TOK_TAIL=""
unset ABX_TOK_HEAD ABX_TOK_TAIL

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
