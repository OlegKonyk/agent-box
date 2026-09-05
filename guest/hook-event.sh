#!/bin/bash
#
# agent-box — the hook command. One line of JSON per hook event.
#
# Runs in the guest, as the unprivileged guest user, invoked by Claude Code
# itself through guest/hooks.settings.json. Claude Code hands it one JSON
# object on standard input and reads nothing back that matters here: this is a
# sensor, not a gate.
#
# Where the line goes is decided by AGENT_BOX_EVENTS_DIR, exported by
# agent-run.sh or claude-session.sh before the CLI starts. Unset means the CLI
# was launched some other way, and the right answer then is to do nothing:
# writing to a guessed directory is how a session's tool inputs end up
# somewhere nobody is watching.
#
# It ALWAYS exits 0. A non-zero exit from a PreToolUse hook blocks the tool,
# and an observer that can stop the thing it is observing is not an observer.

set -uo pipefail

DIR="${AGENT_BOX_EVENTS_DIR:-}"
[ -n "$DIR" ]  || exit 0
[ -d "$DIR" ]  || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# The destination comes from the environment, and the environment of a process
# the agent can start. Resolve it and refuse anything outside the state root:
# a nested CLI launched with AGENT_BOX_EVENTS_DIR=/work/.agent-box would
# otherwise append the model's own tool inputs onto the host's disk and into
# its backups, in a file the run's leak check no longer reads because it checks
# the path it was given rather than the path that was written.
STATE_ROOT="${ABX_STATE_DIR:-${HOME}/.agent-box}"
RESOLVED=$(cd "$DIR" 2>/dev/null && pwd -P) || exit 0
ROOT_RESOLVED=$(cd "$STATE_ROOT" 2>/dev/null && pwd -P) || exit 0
case "$RESOLVED" in
    "$ROOT_RESOLVED"/*) ;;
    *) exit 0 ;;
esac

# And the file itself must be a regular file, not a symlink pointing out of the
# tree the check above just confined us to.
TARGET="${RESOLVED}/hooks.jsonl"
[ ! -L "$TARGET" ] || exit 0
[ ! -e "$TARGET" ] || [ -f "$TARGET" ] || exit 0

PAYLOAD=$(cat 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# input_head is one short line, chosen per tool: the field a person scanning a
# log actually wants. Truncated to 120 characters because this is a log line,
# not a record of the call — and because tool inputs are model output, which is
# untrusted text that ends up on the host's terminal through `agentbox logs`.
#
# `ok` is three-valued on purpose: true after a tool that returned, false after
# one that failed, null for the events where success is not a question.
LINE=$(printf '%s' "$PAYLOAD" | jq -c --arg ts "$TS" '
  def head120:
      if . == null then null
      else (tostring | split("\n")[0] | .[0:120])
      end;
  (.tool_name // "")        as $tool  |
  ((.tool_input // {}) | if type == "object" then . else {} end) as $in |
  {
    ts:         $ts,
    event:      (.hook_event_name // null),
    session_id: (.session_id // null),
    tool:       (if $tool == "" then null else $tool end),
    input_head: (
        (if   $tool == "Bash"                        then $in.command
          elif $tool == "Agent" or $tool == "Task"   then $in.description
          elif $tool == "Grep"  or $tool == "Glob"   then $in.pattern
          elif $in.file_path   != null               then $in.file_path
          elif $in.command     != null               then $in.command
          elif $in.pattern     != null               then $in.pattern
          elif $in.description != null               then $in.description
          else (.message // .prompt // null)
          end) | head120
    ),
    ok: (
        if   (.hook_event_name // "") == "PostToolUseFailure" then false
        elif ((.tool_response | type) == "object")
             and ((.tool_response.is_error // false) == true) then false
        elif (.hook_event_name // "") == "PostToolUse"        then true
        else null
        end
    )
  }
' 2>/dev/null) || exit 0

[ -n "$LINE" ] || exit 0

# 600, like every other file in a run directory. A single short line appended
# with one write stays whole; a reader that splits on newlines never sees half
# of one.
umask 077
printf '%s\n' "$LINE" >> "$TARGET"
exit 0
