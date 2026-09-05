#!/bin/bash
#
# agent-box — start, stop and list the tmux sessions a box is running.
#
# Runs in the guest, as the unprivileged guest user. Invoked by
# `agentbox run`, `agentbox stop-run` and `agentbox sessions`.
#
# Usage:
#   run-ctl.sh start --runid R --slug S --brief PATH [--model M]
#                    [--max-turns N] [--max-budget-usd X]
#   run-ctl.sh stop  [runid]
#   run-ctl.sh sessions [--json]
#   run-ctl.sh state [runid]
#   run-ctl.sh runs [--json]
#   run-ctl.sh reconcile
#   run-ctl.sh latest
#
# Why this exists rather than the host assembling tmux commands: the host CLI's
# job is to talk to limactl, and nothing else. A `tmux new-session -d -s ...`
# built on the host is guest knowledge written down in the wrong place, in a
# string no linter reads and no test can run on its own.

set -uo pipefail

die() { printf 'run-ctl: %s\n' "$*" >&2; exit 1; }

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

command -v tmux >/dev/null 2>&1 || die "tmux is not installed in this guest"

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------

cmd_start() {
    local runid="" slug="task" model="sonnet" brief="" max_turns="" max_budget=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --runid)          runid="${2:?--runid needs a value}"; shift 2 ;;
            --slug)           slug="${2:?--slug needs a value}"; shift 2 ;;
            --model)          model="${2:?--model needs a value}"; shift 2 ;;
            --brief)          brief="${2:?--brief needs a value}"; shift 2 ;;
            --max-turns)      max_turns="${2:?--max-turns needs a value}"; shift 2 ;;
            --max-budget-usd) max_budget="${2:?--max-budget-usd needs a value}"; shift 2 ;;
            *) die "unknown argument: $1" ;;
        esac
    done

    [ -n "$runid" ] || die "start needs --runid"
    [ -n "$brief" ] || die "start needs --brief"
    # A bare name is a file the host has already copied into the briefs
    # directory. That keeps the guest home's location out of the host CLI,
    # which does not know what the guest user's home is called.
    case "$brief" in /*) ;; *) brief="${ABX_BRIEFS_DIR}/${brief}" ;; esac
    [ -f "$brief" ] || die "brief not found: ${brief}"

    local session="run-${runid}"
    if tmux has-session -t "=${session}" 2>/dev/null; then
        die "a tmux session named ${session} is already running"
    fi

    local args=(--runid "$runid" --slug "$slug" --model "$model"
                --brief "$brief" --session "$session")
    [ -n "$max_turns" ]  && args+=(--max-turns "$max_turns")
    [ -n "$max_budget" ] && args+=(--max-budget-usd "$max_budget")

    # Detached, so the limactl shell that started it can return immediately.
    # The tmux server outlives that shell, which is the whole point: a run is
    # not tied to the terminal that launched it.
    tmux new-session -d -s "$session" -- \
        "${ABX_LIB_DIR}/agent-run.sh" "${args[@]}" \
        || die "tmux refused to start ${session}"

    # Do not return until the run is readable. The caller's next move is
    # `logs`, `runs` or `--wait`, and every one of those looks for meta.json;
    # returning the instant tmux forks would race the run into existence and
    # report "no such run" for a run that was about to be perfectly fine.
    local dir waited=0
    dir=$(abx_run_dir "$runid")
    while [ "$waited" -lt 30 ]; do
        [ -f "${dir}/meta.json" ] && break
        sleep 1
        waited=$((waited + 1))
    done
    [ -f "${dir}/meta.json" ] \
        || printf 'run-ctl: WARNING: %s has not written meta.json after %ss\n' "$runid" "$waited" >&2

    printf '%s\n' "$session"
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------
#
# SIGINT to the claude process, not SIGKILL to the session. Claude Code treats
# an interrupt as "stop after this step", so the run gets the chance to write
# its result event; killing the pane leaves the run directory saying `running`
# for ever. The session is only killed once the status file has moved, or after
# 20 seconds, whichever comes first.

cmd_stop() {
    local runid="${1:-}" dir state session pane_pid waited

    if [ -z "$runid" ]; then
        # The newest RUNNING run, not simply the newest. A quick task started
        # after the long one finishes first, and `stop-run` with no argument
        # would otherwise address the finished one and leave the long one
        # burning budget, while printing that it had stopped something.
        runid=$(newest_running) || true
        if [ -z "$runid" ]; then
            die "no run is running. 'agentbox runs <repo>' lists what there is."
        fi
        printf 'run-ctl: stopping %s, the newest running run\n' "$runid"
    fi

    dir=$(abx_run_dir "$runid")
    [ -d "$dir" ] || die "no such run: ${runid}"

    state=$(abx_status_read "$dir")
    if [ "$state" != "running" ]; then
        die "run ${runid} already ended with ${state}; refusing to overwrite its record"
    fi

    session="run-${runid}"
    if ! tmux has-session -t "=${session}" 2>/dev/null; then
        # The status says running and the session is gone. That is the orphan
        # case, and it has its own state: `exit:lost` says the run's fate is
        # unknown, which is true, where `exit:stopped` would claim this command
        # stopped something it never reached.
        reconcile_run "$runid"
        printf 'run-ctl: %s has no tmux session; recorded it as %s\n' \
            "$runid" "$(abx_status_read "$dir")"
        return 0
    fi

    # Before any signal, and after the check above: the run reads this file in
    # its exit trap and records `exit:stopped` itself. The stopper cannot tell
    # an interrupted run from one that happened to finish in the same second,
    # and Claude Code exits 0 on an interrupt (issue #14), so inferring it from
    # out here recorded stopped runs as `done`. The run knows; this is how it
    # is told to look.
    printf '%s\n' "$(abx_now_iso)" > "${dir}/stop-requested"
    chmod 600 "${dir}/stop-requested" 2>/dev/null || true

    # The CLI, and only the CLI.
    #
    # Signalling every process under the pane hits two things that are not the
    # CLI: agent-run.sh itself, and the console tee holding the read end of its
    # stdout. Killing the tee left agent-run.sh writing into a pipe nobody was
    # reading, so it died of SIGPIPE without running its exit trap — no
    # summary, and no status written by the one process that knew what had
    # happened. That is why the run records its own pid for the CLI, and why
    # this walks down from there rather than down from the pane.
    local claude_pid pids="" pid signalled=0
    claude_pid=$(cat "${dir}/claude-pid" 2>/dev/null | head -1) || claude_pid=""
    case "$claude_pid" in ''|*[!0-9]*) claude_pid="" ;; esac

    pane_pid=$(tmux list-panes -t "=${session}" -F '#{pane_pid}' 2>/dev/null | head -1)

    if [ -n "$claude_pid" ] && kill -0 "$claude_pid" 2>/dev/null; then
        pids=$(descendants_deepest_first "$claude_pid")
        for pid in $pids; do
            kill -INT "$pid" 2>/dev/null && signalled=$((signalled + 1))
        done
        if [ "$signalled" -eq 0 ]; then
            printf 'run-ctl: WARNING: could not signal the CLI (pid %s); is procps installed?\n' \
                "$claude_pid" >&2
        fi
    else
        # No CLI running: the run is still in its preconditions, or already on
        # its way out. Interrupt the script itself, which has a trap for it.
        printf 'run-ctl: no CLI process for %s yet; interrupting the run script\n' "$runid"
        [ -z "$pane_pid" ] || kill -INT "$pane_pid" 2>/dev/null || true
    fi

    waited=0
    while [ "$waited" -lt 20 ]; do
        [ "$(abx_status_read "$dir")" = "running" ] || break
        tmux has-session -t "=${session}" 2>/dev/null || break
        sleep 1
        waited=$((waited + 1))
    done

    # The run may have recorded its own exit while we waited. That code is the
    # truth about what happened and this command does not get to overwrite it.
    state=$(abx_status_read "$dir")
    if [ "$state" != "running" ]; then
        tmux kill-session -t "=${session}" 2>/dev/null || true
        case "$state" in
            exit:stopped)
                printf 'run-ctl: %s stopped after %ss. Nothing was reverted: the work tree is as the run left it.\n' \
                    "$runid" "$waited" ;;
            exit:0)
                # "By itself" is reserved for a run that really did finish on
                # its own terms while we were waiting, which is the one case
                # where this command changed nothing.
                printf 'run-ctl: %s ended by itself after %ss with %s; nothing was reverted\n' \
                    "$runid" "$waited" "$state" ;;
            *)
                printf 'run-ctl: %s ended after %ss with %s; nothing was reverted\n' \
                    "$runid" "$waited" "$state" ;;
        esac
        return 0
    fi

    tmux kill-session -t "=${session}" 2>/dev/null || true

    # exit:stopped is a claim that the run is over, so it is written only once
    # that has been observed: no session, and no surviving pane process.
    local gone=0 tries=0
    while [ "$tries" -lt 10 ]; do
        if process_tree_gone "$pane_pid" "$session"; then gone=1; break; fi
        sleep 1
        tries=$((tries + 1))
    done

    if [ "$gone" -ne 1 ]; then
        printf 'run-ctl: %s did not stop: its session or its process is still there after %ss.\n' \
            "$runid" "$((waited + tries))" >&2
        printf 'run-ctl: the run is left recorded as running rather than claimed to be stopped.\n' >&2
        return 1
    fi

    # Worded differently from the branch above on purpose. There, the run
    # recorded its own stop and this command only reported it. Here it did not,
    # so the session was closed and the status written from outside — a
    # materially weaker claim, and one an operator should be able to tell apart.
    abx_status_write "$dir" "exit:stopped"
    printf 'run-ctl: %s stopped after %ss by closing its session; it did not record its own exit. Nothing was reverted.\n' \
        "$runid" "$waited"
}

# No tmux session, and no pane process. Both, because either alone can be true
# of a run that is still going.
process_tree_gone() {
    local pane="${1:-}" session="${2:?}"
    tmux has-session -t "=${session}" 2>/dev/null && return 1
    [ -n "$pane" ] || return 0
    kill -0 "$pane" 2>/dev/null && return 1
    [ -z "$(pgrep -P "$pane" 2>/dev/null)" ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# reconcile
# ---------------------------------------------------------------------------
#
# A run whose process died without running its EXIT trap — the VM stopped under
# it, a stray `tmux kill-server`, the guest out of memory — leaves `running` in
# its status file for ever. `runs` then lists it as running, `status` shows an
# elapsed time that grows without end, and `logs -f` blocks with nothing coming.
#
# So `runs`, `status` and `agentbox start` reconcile first: a run that says it
# is running, has no tmux session, and whose recorded pid is not alive, becomes
# `exit:lost`. Lost rather than failed, because what happened to it is exactly
# what nobody knows.

reconcile_run() {
    local runid="${1:?}" dir pid
    dir="${ABX_RUNS_DIR}/${runid}"
    [ -d "$dir" ] || return 0
    [ "$(abx_status_read "$dir")" = "running" ] || return 0
    tmux has-session -t "=run-${runid}" 2>/dev/null && return 0
    pid=$(cat "${dir}/pid" 2>/dev/null) || pid=""
    case "$pid" in
        ''|*[!0-9]*) ;;
        *) kill -0 "$pid" 2>/dev/null && return 0 ;;
    esac
    abx_status_write "$dir" "exit:lost"
    printf 'run-ctl: %s was left recorded as running with nothing behind it; marked exit:lost\n' \
        "$runid" >&2
}

cmd_reconcile() {
    local d runid
    [ -d "$ABX_RUNS_DIR" ] || return 0
    for d in "$ABX_RUNS_DIR"/*/; do
        [ -f "${d}meta.json" ] || continue
        d=${d%/}
        runid=${d##*/}
        abx_valid_runid "$runid" || continue
        reconcile_run "$runid"
    done
}

# The newest run whose status is still `running`, or nothing.
newest_running() {
    local d runid newest=""
    [ -d "$ABX_RUNS_DIR" ] || return 1
    for d in "$ABX_RUNS_DIR"/*/; do
        [ -f "${d}meta.json" ] || continue
        d=${d%/}
        runid=${d##*/}
        abx_valid_runid "$runid" || continue
        [ "$(abx_status_read "$d")" = "running" ] || continue
        newest="$runid"
    done
    [ -n "$newest" ] || return 1
    printf '%s\n' "$newest"
}

# Depth-first pid list under a root pid, children before parents.
descendants_deepest_first() {
    local root="${1:?}" child
    # shellcheck disable=SC2046  # one pid per line is exactly what is wanted.
    for child in $(pgrep -P "$root" 2>/dev/null); do
        descendants_deepest_first "$child"
    done
    printf '%s\n' "$root"
}

# ---------------------------------------------------------------------------
# sessions
# ---------------------------------------------------------------------------

# The raw list, as JSON, built by jq so that a session name containing a quote
# or a brace cannot forge or erase an entry. Printing is somebody else's job:
# see cmd_sessions.
sessions_json() {
    local now raw name created fmt first=1
    now=$(date +%s)
    # A REAL tab, produced by printf, because tmux does not expand \t in a
    # format string — it emits a literal backslash and a t, which puts the
    # timestamp inside the name and leaves every age at zero. The creation time
    # comes first as well, so that a name containing a tab, a space or a
    # newline cannot be mistaken for the field before it.
    fmt=$(printf '#{session_created}\t#{session_name}')
    raw=$(tmux list-sessions -F "$fmt" 2>/dev/null) || raw=""

    printf '['
    while IFS=$'\t' read -r created name; do
        [ -n "$name" ] || continue
        case "$created" in ''|*[!0-9]*) created="$now" ;; esac
        [ "$first" -eq 1 ] || printf ','
        first=0
        jq -cn --arg name "$name" \
               --argjson age "$((now - created))" \
               --argjson last "$(last_event_json "$name")" \
               '{name: $name, age_s: $age, last_event: $last}'
    done <<< "$raw"
    printf ']'
}

# Through run-format.py, like every other output. A tmux session name is chosen
# by whoever created the session, and inside a run that is the agent: one
# `tmux new-session -s "$CLAUDE_CODE_OAUTH_TOKEN"` would otherwise print the
# whole credential to the host terminal. This was the one guest-to-host path
# that never met the scrubber.
cmd_sessions() {
    local as_json=""
    [ "${1:-}" = "--json" ] && as_json="--json"
    sessions_json | python3 "${ABX_LIB_DIR}/run-format.py" --sessions-in $as_json
}

# The last hook event a session recorded, which is the cheapest honest answer
# to "is anything still happening in there". Interactive sessions keep theirs
# under ~/.agent-box/sessions/<name>; a run keeps its under the run directory.
# Always valid JSON, so the jq above can take it with --argjson.
session_hooks_file() {
    local name="${1:?}"
    case "$name" in
        run-*)
            abx_valid_runid "${name#run-}" || return 1
            printf '%s/hooks.jsonl' "$(abx_run_dir "${name#run-}")" ;;
        *)
            abx_valid_session_name "$name" || return 1
            printf '%s/hooks.jsonl' "$(abx_session_dir "$name")" ;;
    esac
}

last_event_json() {
    local f out
    f=$(session_hooks_file "$1" 2>/dev/null) || { printf 'null'; return 0; }
    [ -n "$f" ] && [ -s "$f" ] || { printf 'null'; return 0; }
    out=$(tail -1 "$f" | jq -c '{ts: .ts, event: .event}' 2>/dev/null) || out=""
    [ -n "$out" ] || out="null"
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# latest
# ---------------------------------------------------------------------------

# The raw contents of a run's status file: `running`, `exit:<code>` or
# `exit:stopped`. The host reads this to decide what `run --wait` should exit
# with and when a `--notify` watcher should fire.
cmd_state() {
    local runid="${1:-}"
    if [ -z "$runid" ]; then
        runid=$(cmd_latest) || true
        [ -n "$runid" ] || { printf 'unknown\n'; return 0; }
    fi
    abx_status_read "$(abx_run_dir "$runid")"
}

# `runs`, with the orphan reconciliation in front of it, in one round trip.
cmd_runs() {
    cmd_reconcile
    exec python3 "${ABX_LIB_DIR}/run-format.py" --list "$@"
}

cmd_latest() {
    [ -d "$ABX_RUNS_DIR" ] || return 1
    local newest=""
    local d
    for d in "$ABX_RUNS_DIR"/*/; do
        [ -f "${d}meta.json" ] || continue
        d=${d%/}
        newest=${d##*/}
    done
    [ -n "$newest" ] || return 1
    printf '%s\n' "$newest"
}

# ---------------------------------------------------------------------------

case "${1:-}" in
    start)    shift; cmd_start "$@" ;;
    stop)     shift; cmd_stop "$@" ;;
    sessions)  shift; cmd_sessions "$@" ;;
    state)     shift; cmd_state "$@" ;;
    runs)      shift; cmd_runs "$@" ;;
    reconcile) shift; cmd_reconcile ;;
    latest)    shift; cmd_latest ;;
    *) die "usage: run-ctl.sh start|stop|sessions|state|runs|reconcile|latest" ;;
esac
