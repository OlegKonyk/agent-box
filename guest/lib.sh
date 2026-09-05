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
abx_assert_settings_carry_no_credential() {
    local settings="${ABX_CLAUDE_CONFIG_DIR}/settings.json" found
    [ -f "$settings" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0

    found=$(python3 - "$settings" <<'PY' 2>/dev/null
import json, sys

BANNED = ("env", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport")

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(0)

if not isinstance(data, dict):
    raise SystemExit(0)

hits = [k for k in BANNED if k in data]


def scan(node, path):
    if isinstance(node, dict):
        for k, v in node.items():
            scan(v, path + [str(k)])
    elif isinstance(node, list):
        for i, v in enumerate(node):
            scan(v, path + [str(i)])
    elif isinstance(node, str) and node.startswith("sk-ant-"):
        hits.append(".".join(path))


scan(data, [])
print(" ".join(sorted(set(hits))))
PY
    )

    [ -z "$found" ] || die "${settings} carries credential-bearing keys (${found}); they would outrank the subscription token. Remove them, or let sync-claude-config.sh strip them by putting the file on the host config mount."
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
