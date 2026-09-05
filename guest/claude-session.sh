#!/bin/bash
#
# agent-box — an interactive Claude Code session inside the guest, at /work.
#
# Runs in the guest, as the unprivileged guest user. Invoked by
# `agentbox claude <repo> [claude args...]` and by `agentbox session <repo>`.
#
# Usage: claude-session.sh [--tmux NAME] [--session-name NAME]
#                          [--brief PATH] [--model M] [claude args...]
#
# This is the interactive half of the box. `agentbox run` is the headless half
# and gets a scrubbed summary, a branch and a leak check; this one hands the
# terminal straight to the CLI, which is what makes it useful and also what
# makes it unscrubbed — see docs/decisions.md. The preconditions are the same
# ones agent-run.sh insists on, from the same file, because "an interactive
# session" is not a reason to run an agent with the firewall down or with an
# API key quietly outranking the subscription token.
#
# --tmux runs the session inside a named tmux session so it can be left and
# come back to. The token is exported only in the inner invocation, never in
# the process that starts the tmux server: a tmux server holds the environment
# of whichever client started it and hands it to every later session, so
# exporting the credential on the outside would put it in sessions that have
# nothing to do with the agent.

set -uo pipefail

die() { printf 'agent-box claude: %s\n' "$*" >&2; exit 1; }

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SELF="${ABX_LIB_DIR}/claude-session.sh"
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

WORK_DIR="${AGENT_BOX_WORK:-/work}"
export TZ=UTC

TMUX_NAME=""
SESSION_NAME=""
BRIEF=""
MODEL=""
FORWARD=()

while [ $# -gt 0 ]; do
    case "$1" in
        --tmux)         TMUX_NAME="${2:?--tmux needs a value}"; shift 2 ;;
        --session-name) SESSION_NAME="${2:?--session-name needs a value}"; shift 2 ;;
        --brief)        BRIEF="${2:?--brief needs a value}"; shift 2 ;;
        --model)        MODEL="${2:?--model needs a value}"; shift 2 ;;
        *)              FORWARD+=("$1"); shift ;;
    esac
done

abx_assert_environment die

[ -d "$WORK_DIR" ] || die "${WORK_DIR} is not mounted"

# ---------------------------------------------------------------------------
# The outer half: put the session inside tmux and hand over
# ---------------------------------------------------------------------------
#
# `new-session -A` attaches to the session if it is already there and creates
# it otherwise, which is exactly what "leave it and come back" means. When it
# attaches, the command below is ignored — the session that is already running
# keeps running.

if [ -n "$TMUX_NAME" ]; then
    command -v tmux >/dev/null 2>&1 || die "tmux is not installed in this guest"
    INNER=("$SELF" --session-name "$TMUX_NAME")
    [ -n "$BRIEF" ] && INNER+=(--brief "$BRIEF")
    [ -n "$MODEL" ] && INNER+=(--model "$MODEL")
    [ "${#FORWARD[@]}" -gt 0 ] && INNER+=("${FORWARD[@]}")
    exec tmux new-session -A -s "$TMUX_NAME" -- "${INNER[@]}"
fi

# ---------------------------------------------------------------------------
# The inner half: the session itself
# ---------------------------------------------------------------------------

SETTINGS_ARGS=()
if [ -n "$SESSION_NAME" ]; then
    SESSION_DIR=$(abx_session_dir "$SESSION_NAME")
    abx_private_dir "$ABX_SESSIONS_DIR"
    abx_private_dir "$SESSION_DIR"
    abx_status_write "$SESSION_DIR" "running"
    # Only when there is somewhere to write. hook-event.sh exits 0 doing
    # nothing without this, so wiring the hooks up with nowhere for them to go
    # would spawn a process per tool call to achieve exactly that.
    export AGENT_BOX_EVENTS_DIR="$SESSION_DIR"
    mapfile -t SETTINGS_ARGS < <(abx_hook_settings_args)

    session_finish() {
        local rc=$?
        abx_status_write "$SESSION_DIR" "exit:${rc}"
    }
    trap session_finish EXIT
fi

# Session-only plugin roots from the read-only host config mount.
PLUGIN_ARGS=()
mapfile -t PLUGIN_ARGS < <(abx_plugin_dir_args)
abx_report_plugin_dirs "${PLUGIN_ARGS[@]}"

MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=(--model "$MODEL")

# The brief becomes the session's first prompt. It is read here rather than
# passed as a path, so a brief that has already been copied into the guest can
# be deleted afterwards without the session losing it.
PROMPT_ARGS=()
if [ -n "$BRIEF" ]; then
    # A bare name is a file the host has already copied into the briefs
    # directory, the same convention run-ctl.sh uses: the host CLI does not
    # know what the guest user's home is called and must not have to guess.
    case "$BRIEF" in /*) ;; *) BRIEF="${ABX_BRIEFS_DIR}/${BRIEF}" ;; esac
    [ -f "$BRIEF" ] || die "brief not found: ${BRIEF}"
    PROMPT_ARGS=("$(cat "$BRIEF")")
fi

abx_export_token

cd "$WORK_DIR" || die "cannot enter ${WORK_DIR}"

# exec, so the CLI owns the terminal and its exit status is the one the host
# sees. The token is in this process's environment and goes no further: it is
# not on the guest's disk outside the 0600 token file, not in argv, and not in
# anything written to /work.
#
# With a session directory the EXIT trap above has to run, so the CLI is a
# child rather than a replacement: without that, a session would stay `running`
# for ever after it ended.
if [ -n "$SESSION_NAME" ]; then
    claude "${PLUGIN_ARGS[@]}" "${SETTINGS_ARGS[@]}" "${MODEL_ARGS[@]}" \
        "${FORWARD[@]}" "${PROMPT_ARGS[@]}"
    exit $?
fi

exec claude "${PLUGIN_ARGS[@]}" "${MODEL_ARGS[@]}" "${FORWARD[@]}" "${PROMPT_ARGS[@]}"
