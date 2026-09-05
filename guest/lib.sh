#!/bin/bash
#
# agent-box — shared guest-side helpers.
#
# Sourced, never executed. Three scripts need the same preconditions and the
# same token handling before they may launch Claude Code:
#
#   guest/agent-run.sh        one headless task
#   guest/verify-auth.sh      one small model call
#   guest/claude-session.sh   an interactive session
#   guest/run-ctl.sh          start, stop and list the tmux sessions those use
#   guest/box-status.sh       one JSON line describing this box
#
# Having that logic in one file is not tidiness: each of these exports a
# personal OAuth token into a process, and three copies of "is an API key set,
# is the firewall up, is the token file 600" is three places for one of them to
# drift into being weaker than the others.
#
# Contract: the sourcing script MUST define die() before sourcing this file.
# Each caller words its own failures differently — verify-auth prints
# "FAIL — ...", agent-run prints a bare message — and the messages are asserted
# by test/smoke.sh, so the wording belongs to the caller.

# The token file. Written by `agentbox token <repo>` on the host, straight down
# a pipe into the guest, mode 600.
ABX_TOKEN_FILE="${ABX_TOKEN_FILE:-${HOME}/.config/agent-box/token}"

# The host's ~/.config/agent-box/guest, mounted read-only. May be empty.
ABX_CONFIG_MOUNT="${AGENT_BOX_CONFIG_DIR:-/opt/agent-box-config}"

# Optional per-plugin roots for --plugin-dir, one directory per plugin.
ABX_PLUGIN_DIR_ROOT="${ABX_PLUGIN_DIR_ROOT:-${ABX_CONFIG_MOUNT}/plugin-dir}"

# The guest's own Claude Code configuration directory.
ABX_CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"

# The one mounted repository. Named here as well as in the callers, because the
# preconditions below have to look inside it: the repository's own
# .claude/settings.json is live in a folder this VM marks trusted.
ABX_WORK_DIR="${AGENT_BOX_WORK:-/work}"

# ---------------------------------------------------------------------------
# Run and session state
# ---------------------------------------------------------------------------
#
# All of it lives in the guest home, never on the host mount. A run's raw event
# stream is the model's own output, and /work is the host's disk: a transcript
# written there would land in the host's filesystem and its backups. Only the
# scrubbed summary crosses.

ABX_STATE_DIR="${ABX_STATE_DIR:-${HOME}/.agent-box}"
ABX_RUNS_DIR="${ABX_RUNS_DIR:-${ABX_STATE_DIR}/runs}"
ABX_SESSIONS_DIR="${ABX_SESSIONS_DIR:-${ABX_STATE_DIR}/sessions}"
ABX_BRIEFS_DIR="${ABX_BRIEFS_DIR:-${ABX_STATE_DIR}/briefs}"

# The hooks block that turns tool activity into hooks.jsonl. Passed with
# --settings, which merges rather than replaces, so nothing the operator
# configured is lost.
ABX_HOOK_SETTINGS="${ABX_HOOK_SETTINGS:-/opt/agent-box/guest/hooks.settings.json}"

# The native installer puts claude in ~/.local/bin, which a non-login shell
# does not pick up. `limactl shell <inst> -- <script>` is such a shell.
export PATH="${HOME}/.local/bin:${PATH}"

if ! declare -F die >/dev/null 2>&1; then
    printf 'lib.sh: the sourcing script must define die() before sourcing this file\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
#
# Claude Code's settings.json can hold or mint a credential of its own: `env`
# is merged into the CLI's process environment, so an ANTHROPIC_API_KEY there
# arrives AFTER the shell-environment check below has passed and silently
# outranks the subscription token; `apiKeyHelper` is a command the CLI runs to
# produce a key; the AWS keys do the same for Bedrock. sync-claude-config.sh
# strips all of them on the way in, but the guarantee is worth enforcing where
# the token is exported rather than only where the file is copied — the file
# can also be edited inside the guest, and a stale copy can outlive the sync
# that made it.
#
# A file that does not parse is left alone: the CLI would not read it either,
# and refusing to launch over a broken settings file helps nobody.
abx_scan_settings_file() {
    local settings="${1:?}" mode="${2:-config}"
    [ -f "$settings" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    python3 - "$settings" "$mode" <<'SETTINGS_SCAN' 2>/dev/null
import json, sys

BANNED = ("env", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport")

path, mode = sys.argv[1], sys.argv[2]

try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(0)

if not isinstance(data, dict):
    raise SystemExit(0)

hits = [k for k in BANNED if k in data]

# A `hooks` block is a list of commands the CLI will run. In the operator's own
# configuration that is their choice; in the REPOSITORY's settings it is a
# command chosen by whoever wrote the repository, running in a process tree
# that holds the subscription token, in a folder this VM marks trusted on the
# operator's behalf. That is the one place it is nobody's choice.
if mode == "repo" and "hooks" in data:
    hits.append("hooks")


def scan(node, trail):
    if isinstance(node, dict):
        for k, v in node.items():
            scan(v, trail + [str(k)])
    elif isinstance(node, list):
        for i, v in enumerate(node):
            scan(v, trail + [str(i)])
    elif isinstance(node, str) and node.startswith("sk-ant-"):
        hits.append(".".join(trail))


scan(data, [])
print(" ".join(sorted(set(hits))))
SETTINGS_SCAN
}

abx_assert_settings_carry_no_credential() {
    local settings="${ABX_CLAUDE_CONFIG_DIR}/settings.json" found work
    found=$(abx_scan_settings_file "$settings" config)
    [ -z "$found" ] || die "${settings} carries credential-bearing keys (${found}); they would outrank the subscription token. Remove them, or let sync-claude-config.sh strip them by putting the file on the host config mount."

    # And the repository's own settings, which nothing filters on the way in
    # because they arrive on a mount rather than through sync-claude-config.sh.
    # /work is marked trusted by design, which is exactly what makes those files
    # live rather than inert — see docs/decisions.md.
    for work in "${ABX_WORK_DIR}/.claude/settings.json" \
                "${ABX_WORK_DIR}/.claude/settings.local.json"; do
        found=$(abx_scan_settings_file "$work" repo)
        [ -z "$found" ] || die "${work} carries keys this box will not run with (${found}). It is the repository's own file: a credential there would outrank the subscription token, and a hooks block there is a command chosen by the repository, running in a process that holds the token. Remove it, or review it and move it out of the tree."
    done
}

# Everything that must be true before a token is exported into a process.
# Called with the firewall policy this caller wants:
#
#   die   — refuse to run at all (agent-run, claude-session: these turn an
#           agent loose, and an agent with unrestricted egress is the thing
#           this VM exists to prevent)
#   warn  — say so and continue (verify-auth: a one-shot call whose entire job
#           is to diagnose, and refusing to diagnose is unhelpful)
abx_assert_environment() {
    local firewall_policy="${1:-die}" mode

    [ "$(id -u)" -ne 0 ] || die "refusing to run as root: Claude Code rejects --dangerously-skip-permissions for root, and the whole point of the guest user is that it is not root"

    [ -f "$ABX_TOKEN_FILE" ] || die "no token at ${ABX_TOKEN_FILE}. Run 'agentbox token <repo>' on the host first."
    mode=$(stat -c '%a' "$ABX_TOKEN_FILE")
    [ "$mode" = "600" ] || die "${ABX_TOKEN_FILE} has mode ${mode}; expected 600"

    # An API key silently outranks the OAuth token, which would bill an API
    # account instead of drawing on the subscription. Refuse rather than
    # surprise.
    [ -z "${ANTHROPIC_API_KEY:-}" ]    || die "ANTHROPIC_API_KEY is set; it would override the subscription token. Unset it."
    [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] || die "ANTHROPIC_AUTH_TOKEN is set; it would override the subscription token. Unset it."

    command -v claude >/dev/null 2>&1 || die "claude is not on PATH"

    abx_assert_settings_carry_no_credential

    if ! systemctl is-active --quiet agent-box-firewall.service; then
        case "$firewall_policy" in
            warn) printf 'WARNING — the egress firewall is not active\n' >&2 ;;
            *)    die "the egress firewall is not active; refusing to run an agent with unrestricted network" ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# The token
# ---------------------------------------------------------------------------
#
# Read it without it ever appearing in argv, in a log, or on a terminal, and
# keep the first and last eight characters so output that reaches the host can
# be scrubbed or checked. Eight at each end is enough to recognise the
# credential without reconstituting it. Neither fragment is ever printed.
#
# The content is checked, not just the file's existence and mode. An empty
# token file is not a hypothetical: the guest-side write is a `cat >` down a
# pipe that an interrupted `limactl shell` can truncate, and the file can be
# edited inside the guest. Empty fragments would then turn the leak check into
# `grep -F -e '' -e ''`, which matches every non-empty stream and reports a
# leak on every run, and would turn the scrubber into a corrupter, since bash
# inserts the replacement between every character of a substitution on the
# empty string. Both failures land exactly when someone is trying to work out
# why the box is broken.
abx_export_token() {
    CLAUDE_CODE_OAUTH_TOKEN=$(cat "$ABX_TOKEN_FILE")
    export CLAUDE_CODE_OAUTH_TOKEN

    [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] \
        || die "the token file is empty; re-run 'agentbox token <repo>'"
    # 16 is where the head and the tail would start to overlap and over-redact;
    # 20 leaves a margin and is far below any real token's length.
    [ "${#CLAUDE_CODE_OAUTH_TOKEN}" -ge 20 ] \
        || die "the token in ${ABX_TOKEN_FILE} is implausibly short (${#CLAUDE_CODE_OAUTH_TOKEN} chars)"

    ABX_TOK_HEAD="${CLAUDE_CODE_OAUTH_TOKEN:0:8}"
    ABX_TOK_TAIL="${CLAUDE_CODE_OAUTH_TOKEN: -8}"
}

# The head and the tail WITHOUT putting the token in the environment.
#
# Anything that only has to redact — the status script, and the formatter that
# prints a run back to the host terminal — needs the fragments and has no
# business holding the credential. Returns non-zero and sets nothing when there
# is no usable token file, which is the ordinary state of a box before
# `agentbox token`, so the caller scrubs nothing rather than scrubbing wrongly.
abx_load_token_fragments() {
    local tok=""
    [ -f "$ABX_TOKEN_FILE" ] || return 1
    tok=$(cat "$ABX_TOKEN_FILE" 2>/dev/null) || return 1
    # The same 20-character floor abx_export_token applies, and for the same
    # reason: shorter fragments over-redact, and empty ones corrupt.
    if [ "${#tok}" -lt 20 ]; then
        tok=""
        return 1
    fi
    ABX_TOK_HEAD="${tok:0:8}"
    ABX_TOK_TAIL="${tok: -8}"
    tok=""
    return 0
}

abx_forget_token() {
    unset CLAUDE_CODE_OAUTH_TOKEN
}

# Literal parameter substitution, not sed. Building a sed expression out of
# token text treats it as a regex AND as a delimiter: a single slash in the
# fragment makes sed abort with a message quoting the offending expression,
# which prints the fragment unredacted. Quoting the pattern inside
# ${var//pat/rep} makes it literal, needs no escaping, and costs no subprocess.
#
# Guarded against an empty fragment, which would otherwise splice <redacted>
# between every character of the output. `abx_export_token` refuses an empty
# token, so this is the second line of the same defence rather than the first.
abx_scrub_token() {
    local s="$1"
    [ -n "${ABX_TOK_HEAD:-}" ] && s="${s//"$ABX_TOK_HEAD"/<redacted>}"
    [ -n "${ABX_TOK_TAIL:-}" ] && s="${s//"$ABX_TOK_TAIL"/<redacted>}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Session-only plugins
# ---------------------------------------------------------------------------
#
# `claude --plugin-dir <dir>` loads ONE plugin root for that session only: its
# hooks, agents, skills and commands are active for the process and nothing is
# installed. That is the right shape for a plugin still being written on the
# host, which is why the roots live in the read-only config mount rather than
# being installed inside the guest.
#
# Emits one argument per line — `--plugin-dir`, then the path — so a caller can
# read it into an array without splitting on spaces in paths.
abx_plugin_dir_args() {
    local d
    [ -d "$ABX_PLUGIN_DIR_ROOT" ] || return 0
    for d in "$ABX_PLUGIN_DIR_ROOT"/*/; do
        [ -d "$d" ] || continue
        # A directory without a manifest is not a plugin; passing it would make
        # the CLI refuse to start rather than ignore it.
        [ -f "${d}.claude-plugin/plugin.json" ] || continue
        printf '%s\n' '--plugin-dir' "${d%/}"
    done
}

# Say what was loaded. Silence about an active hook is how a session ends up
# behaving in a way nobody can account for.
#
# Takes the argv the caller built — `abx_report_plugin_dirs "${PLUGIN_ARGS[@]}"`
# — rather than scanning the directory again. A second scan is a separate claim
# about a slightly later moment, which makes the line decorative instead of
# evidence about the command that actually ran.
abx_report_plugin_dirs() {
    local i
    for ((i = 2; i <= $#; i += 2)); do
        printf 'session plugin: %s\n' "$(basename "${!i}")"
    done
}

# ---------------------------------------------------------------------------
# Run and session directories
# ---------------------------------------------------------------------------
#
# One directory per run under ~/.agent-box/runs/<runid>, one per interactive
# tmux session under ~/.agent-box/sessions/<name>. Both are mode 700 and hold
# the same `status` file, so a reader does not have to know which kind it is
# looking at.

abx_private_dir() {
    local d="${1:?}" parent
    parent=$(dirname "$d")
    # The parent as well, and before the child. `mkdir -p` creates intermediate
    # directories under the inherited umask, so a run that reaches here on a box
    # whose ~/.agent-box does not exist yet would otherwise create the state
    # root 0755 and everything inside it 700 — the layout the spec states is
    # then not what the code guarantees on its own.
    if [ "$parent" != "$d" ] && [ "$parent" != "/" ]; then
        mkdir -p "$parent"
        chmod 700 "$parent" 2>/dev/null || true
    fi
    mkdir -p "$d"
    chmod 700 "$d"
}

# %Y%m%d-%H%M%S and nothing else. A run id reaches this function from an
# operator's command line, so a plain string join would let `../../.ssh` name a
# directory outside the run tree — and `stop-run` writes a `status` file into
# whatever it is given.
abx_valid_runid() {
    case "${1:-}" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

# tmux names a session; the guest chooses the name, so it is checked before it
# is used to build a path.
abx_valid_session_name() {
    case "${1:-}" in
        ""|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

abx_run_dir() {
    abx_valid_runid "${1:?}" || die "not a run id: ${1}"
    printf '%s/%s' "$ABX_RUNS_DIR" "$1"
}

abx_session_dir() {
    abx_valid_session_name "${1:?}" || die "not a session name: ${1}"
    printf '%s/%s' "$ABX_SESSIONS_DIR" "$1"
}

# `running`, then `exit:<code>` or `exit:stopped`. Written whole, never
# appended: a reader that catches a partial line would report a state that
# never existed.
abx_status_write() {
    local d="${1:?}" v="${2:?}"
    printf '%s\n' "$v" > "${d}/status"
    chmod 600 "${d}/status" 2>/dev/null || true
}

# The five shapes a status may have, and nothing else.
#
# The status file is an ordinary file in the guest user's home and the agent
# runs as that user, so its contents are input. They decide what `stop-run`
# does AND they end up in messages that reach the host's terminal. Anything
# unrecognised reads as `unknown`, and the bytes that were there are never
# returned to a caller, so they cannot be echoed by one.
abx_status_read() {
    local d="${1:?}" raw=""
    [ -f "${d}/status" ] && raw=$(cat "${d}/status" 2>/dev/null | head -1)
    case "$raw" in
        running|exit:stopped|exit:lost) printf '%s\n' "$raw"; return 0 ;;
        exit:*)
            case "${raw#exit:}" in
                ''|*[!0-9]*) ;;
                *) printf '%s\n' "$raw"; return 0 ;;
            esac ;;
    esac
    printf 'unknown\n'
}

# ISO 8601, UTC, second resolution. Every timestamp this project writes uses
# this, so a merged view of two sensors sorts correctly.
abx_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# `--settings <file>` when the hooks settings file is there, nothing when it is
# not. One argument per line, so a caller reads it into an array.
#
# --settings MERGES: the operator's own settings.json is still in force, and
# the hooks below are added to whatever it already declares.
abx_hook_settings_args() {
    [ -f "$ABX_HOOK_SETTINGS" ] || return 0
    printf '%s\n' '--settings' "$ABX_HOOK_SETTINGS"
}

# Does the installed CLI know this flag? `--max-turns` was in the design and is
# not in 2.1.261, so the alternative to asking is a run that dies on "unknown
# option" after the branch has already been made.
abx_claude_supports_flag() {
    local flag="${1:?}"
    command -v claude >/dev/null 2>&1 || return 1
    claude --help 2>/dev/null | grep -q -- "$flag"
}
