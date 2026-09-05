#!/usr/bin/env bash
#
# agent-box — end-to-end smoke test.
#
# Builds throwaway repositories, runs preflight against them, creates a real
# Lima instance, checks the isolation and firewall properties from inside it,
# restarts it to prove provisioning is idempotent under the firewall, and
# destroys it again. Everything it creates is temporary except Lima's downloaded
# image cache, which is deliberately left in place.
#
# Usage: test/smoke.sh
#
# Exit 0 if every check passed, 1 otherwise.
#
# Note on `limactl validate`: it has no --param flag, so validating the bare
# template only ever exercises the /tmp placeholders. To validate the real mount
# paths, this script materialises a copy of the template with the parameters
# substituted the way bin/agentbox passes them and validates that, then confirms
# the substitution with `limactl template yq`. That pair is the runnable form of
# the "validate with params set" requirement.

set -uo pipefail

BOX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AGENTBOX="${BOX_DIR}/bin/agentbox"
LIMACTL="${LIMACTL:-limactl}"

TMP_ROOT=$(mktemp -d -t agent-box-smoke.XXXXXX)
# A hermetic host config dir, so the test never reads, writes or deletes the
# real one. It is mounted read-only into the guest, so it must exist.
export AGENT_BOX_CONFIG_DIR="${TMP_ROOT}/config"
export AGENT_BOX_BLOCKLIST="${AGENT_BOX_CONFIG_DIR}/blocklist.txt"
# Only config/guest is mounted into the VM; blocklist.txt sits in the parent and
# must never appear inside the guest.
mkdir -p "${AGENT_BOX_CONFIG_DIR}/guest"

SMOKE_ID="smoke$$"
CLEAN_REPO="${TMP_ROOT}/${SMOKE_ID}"
DIRTY_REPO="${TMP_ROOT}/dirty-${SMOKE_ID}"
TERM_REPO="${TMP_ROOT}/term-${SMOKE_ID}"
INSTANCE="agent-box-${SMOKE_ID}"

PASS=0
FAIL=0

hr()   { printf '%s\n' '==============================================================='; }
step() { hr; printf '## %s\n' "$*"; hr; }
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

cleanup() {
    local rc=$?
    step "cleanup"
    if "$LIMACTL" list --quiet 2>/dev/null | grep -qxF "$INSTANCE"; then
        printf 'destroying %s\n' "$INSTANCE"
        "$AGENTBOX" destroy "$INSTANCE" || "$LIMACTL" delete --force "$INSTANCE" || true
    fi
    rm -rf "$TMP_ROOT"
    printf 'Lima image cache under ~/Library/Caches/lima/download is left in place on purpose.\n'
    exit "$rc"
}
trap cleanup EXIT

# An explicit --workdir stops limactl from trying to cd into the host's
# working directory inside the guest, which warns on stderr every time.
guest() { "$LIMACTL" shell --workdir /work "$INSTANCE" -- "$@"; }

# A run's own summary, read and scrubbed inside the guest.
guest_summary() {
    "$LIMACTL" shell --workdir /work "$INSTANCE" -- \
        python3 /opt/agent-box/guest/run-format.py --summary "$1"
}

# Run a command with a wall-clock bound and capture its exit status. macOS has
# no `timeout(1)`, and one step below makes a real model call that must not be
# able to wedge the suite.
BOUNDED_RC=0
run_bounded() {
    local secs="$1" out="$2"; shift 2
    "$@" > "$out" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            printf 'run_bounded: exceeded %ss, killing\n' "$secs" >> "$out"
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            BOUNDED_RC=124
            return 124
        fi
        sleep 2; waited=$((waited + 2))
    done
    wait "$pid"; BOUNDED_RC=$?
    return "$BOUNDED_RC"
}

# Wait until the guest answers again. Used after a step that deliberately cuts
# the guest's own network down to loopback.
wait_for_guest() {
    local secs="${1:-120}" waited=0
    while [ "$waited" -lt "$secs" ]; do
        if "$LIMACTL" shell --workdir /work "$INSTANCE" -- true >/dev/null 2>&1; then
            return 0
        fi
        sleep 3; waited=$((waited + 3))
    done
    return 1
}

# ===========================================================================
step "1. preflight on a clean repository (expect exit 0)"
# ===========================================================================

mkdir -p "$CLEAN_REPO"
git init -q "$CLEAN_REPO"
cat > "${CLEAN_REPO}/hello.txt" <<'EOF'
A generic end-to-end test repository. Nothing secret, nothing proprietary.
EOF

"$AGENTBOX" preflight "$CLEAN_REPO"
rc=$?
if [ "$rc" -eq 0 ]; then ok "clean repo preflight exited 0"; else bad "clean repo preflight exited ${rc}, expected 0"; fi

# ===========================================================================
step "2. preflight on a repository with a planted credential (expect exit 1)"
# ===========================================================================

mkdir -p "$DIRTY_REPO"
git init -q "$DIRTY_REPO"
# A syntactically valid but fake AWS access key id: AKIA + 16 uppercase chars.
FAKE_KEY="AKIA$(printf 'QRSTUVWXYZ234567')"
printf 'aws_access_key_id = %s\n' "$FAKE_KEY" > "${DIRTY_REPO}/credentials.ini"

DIRTY_OUT="${TMP_ROOT}/dirty.out"
"$AGENTBOX" preflight "$DIRTY_REPO" > "$DIRTY_OUT" 2>&1
rc=$?
cat "$DIRTY_OUT"

if [ "$rc" -eq 1 ]; then ok "planted-credential preflight exited 1"; else bad "planted-credential preflight exited ${rc}, expected 1"; fi
if grep -q 'credentials.ini' "$DIRTY_OUT"; then ok "the offending path was reported"; else bad "the offending path was not reported"; fi
if grep -qF "$FAKE_KEY" "$DIRTY_OUT"; then bad "the credential itself was echoed"; else ok "the credential itself was not echoed"; fi

# ===========================================================================
step "3. preflight honours the host blocklist, locations only (expect exit 1)"
# ===========================================================================

SECRET_TERM="widgetronic"
printf '%s\n' "$SECRET_TERM" > "$AGENT_BOX_BLOCKLIST"
mkdir -p "$TERM_REPO"
git init -q "$TERM_REPO"
printf 'The %s integration notes.\n' "$SECRET_TERM" > "${TERM_REPO}/notes.md"

TERM_OUT="${TMP_ROOT}/term.out"
"$AGENTBOX" preflight "$TERM_REPO" > "$TERM_OUT" 2>&1
rc=$?
cat "$TERM_OUT"

if [ "$rc" -eq 1 ]; then ok "blocklist preflight exited 1"; else bad "blocklist preflight exited ${rc}, expected 1"; fi
if grep -q 'notes.md' "$TERM_OUT"; then ok "the offending path was reported"; else bad "the offending path was not reported"; fi
if grep -qiF "$SECRET_TERM" "$TERM_OUT"; then bad "the blocklist term was echoed"; else ok "the blocklist term was not echoed"; fi

# ===========================================================================
step "3b. preflight finds a blocklist term that survives only in git history"
# ===========================================================================
#
# The whole .git directory is mounted into the VM, so a term in a commit message
# or in a deleted file is just as readable to the agent as one in the tree.

HIST_REPO="${TMP_ROOT}/hist-${SMOKE_ID}"
mkdir -p "$HIST_REPO"
git init -q "$HIST_REPO"
git -C "$HIST_REPO" config user.name  'smoke test'
git -C "$HIST_REPO" config user.email 'smoke@localhost'
printf 'nothing to see\n' > "${HIST_REPO}/a.txt"
git -C "$HIST_REPO" add a.txt
git -C "$HIST_REPO" commit -q -m "notes about the ${SECRET_TERM} rollout"
# The working tree is clean of the term; only the commit message carries it.
if grep -rqiF "$SECRET_TERM" "$HIST_REPO" --exclude-dir=.git 2>/dev/null; then
    bad "setup error: the term is still in the working tree"
else
    ok "the working tree is clean of the term (history-only case)"
fi

HIST_OUT="${TMP_ROOT}/hist.out"
"$AGENTBOX" preflight "$HIST_REPO" > "$HIST_OUT" 2>&1
rc=$?
cat "$HIST_OUT"
if [ "$rc" -eq 1 ]; then ok "history-only blocklist preflight exited 1"; else bad "history-only blocklist preflight exited ${rc}, expected 1"; fi
if grep -q 'commit message' "$HIST_OUT"; then ok "the offending commit was reported"; else bad "the offending commit was not reported"; fi
if grep -qiF "$SECRET_TERM" "$HIST_OUT"; then bad "the blocklist term was echoed"; else ok "the blocklist term was not echoed from history"; fi

rm -f "$AGENT_BOX_BLOCKLIST"

# ===========================================================================
step "3c. limactl validate with the parameters bin/agentbox actually passes"
# ===========================================================================

PARAM_YAML="${TMP_ROOT}/agent-box-params.yaml"
sed -e "s#^  repo: \"/tmp\"#  repo: \"${CLEAN_REPO}\"#" \
    -e "s#^  box: \"/tmp\"#  box: \"${BOX_DIR}\"#" \
    -e "s#^  config: \"/tmp\"#  config: \"${AGENT_BOX_CONFIG_DIR}/guest\"#" \
    "${BOX_DIR}/lima/agent-box.yaml" > "$PARAM_YAML"

if "$LIMACTL" validate "${BOX_DIR}/lima/agent-box.yaml"; then
    ok "the committed template validates"
else
    bad "the committed template does not validate"
fi

if "$LIMACTL" validate "$PARAM_YAML"; then
    ok "the template validates with real parameters"
else
    bad "the template does not validate with real parameters"
fi

printf -- '--- resolved mounts ---\n'
MOUNTS=$("$LIMACTL" template yq "$PARAM_YAML" '.mounts' 2>&1 | grep -E 'location|mountPoint|writable')
printf '%s\n' "$MOUNTS"
if printf '%s' "$MOUNTS" | grep -q '/opt/agent-box-config'; then
    ok "the host config directory is a declared mount"
else
    bad "the host config directory is not a declared mount"
fi

# ===========================================================================
step "3d. stage the host-side plugin and personal-config files"
# ===========================================================================
#
# Everything here goes into the hermetic config directory, which is mounted
# read-only at /opt/agent-box-config. It must exist BEFORE create, because
# provisioning reads it: the plugin install runs on first boot, after the
# firewall comes up.

GUEST_CFG="${AGENT_BOX_CONFIG_DIR}/guest"
CLAUDE_MARKER="agent-box-smoke-marker-${SMOKE_ID}"
MARKETPLACE_REPO="konyklabs/claude-plugins"
# The registered NAME comes from the marketplace's own manifest, not from the
# repository name: .claude-plugin/marketplace.json on that public repo's main
# branch declares "konyklabs-plugins".
MARKETPLACE_NAME="konyklabs-plugins"
# The plugin the marketplace actually publishes. It was `governor` until that
# repository renamed it; a fixture naming a plugin that no longer exists tests
# the error path and reports it as a broken plugin mechanism.
PLUGIN_UNDER_TEST="supervisor"

mkdir -p "${GUEST_CFG}/claude/rules" \
         "${GUEST_CFG}/plugin-dir/demo/.claude-plugin" \
         "${GUEST_CFG}/plugin-dir/demo/commands"

cat > "${GUEST_CFG}/plugins.txt" <<EOF
# agent-box smoke test
marketplace ${MARKETPLACE_REPO}
install ${PLUGIN_UNDER_TEST}@${MARKETPLACE_NAME}
EOF

cat > "${GUEST_CFG}/claude/CLAUDE.md" <<EOF
# smoke

${CLAUDE_MARKER}
EOF

printf '{}\n' > "${GUEST_CFG}/claude/governor.json"
printf '# a rule\n\nNothing to see.\n' > "${GUEST_CFG}/claude/rules/smoke.md"

# A settings.json shaped like the one a person would really copy in: a harmless
# setting next to an `env` block holding an API key. That block is merged into
# the CLI's own process environment, so it would arrive AFTER the shell
# environment check in lib.sh has already passed. The harmless key must survive
# the crossing and the credential must not.
SETTINGS_HARMLESS_KEY="includeCoAuthoredBy"
SETTINGS_FAKE_KEY="sk-ant-fake-smoke-key-must-not-cross"
cat > "${GUEST_CFG}/claude/settings.json" <<EOF
{
  "${SETTINGS_HARMLESS_KEY}": false,
  "env": {"ANTHROPIC_API_KEY": "${SETTINGS_FAKE_KEY}"},
  "apiKeyHelper": "echo sk-ant-nor-this"
}
EOF

# Staged deliberately: the sync is an allowlist, and a credential-shaped file
# left in the source directory must be refused out loud rather than skipped in
# silence, because a silent skip looks exactly like a successful copy.
printf '{"fake":"this must never be copied into the guest"}\n' > "${GUEST_CFG}/claude/.credentials.json"

cat > "${GUEST_CFG}/plugin-dir/demo/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "demo",
  "description": "A minimal plugin, loaded per session by the agent-box smoke test.",
  "version": "0.1.0"
}
EOF

cat > "${GUEST_CFG}/plugin-dir/demo/commands/hello.md" <<'EOF'
---
description: Say hello from the demo plugin.
---

Reply with the single word: hello
EOF

printf -- '--- staged under %s ---\n' "$GUEST_CFG"
find "$GUEST_CFG" -type f | sed "s#^${GUEST_CFG}/##" | sort
if [ -f "${GUEST_CFG}/plugins.txt" ] && [ -f "${GUEST_CFG}/plugin-dir/demo/.claude-plugin/plugin.json" ]; then
    ok "the host-side plugin and config files are staged"
else
    bad "the host-side plugin and config files are not staged"
fi

# ===========================================================================
step "4. create a real instance from the clean repository"
# ===========================================================================

printf 'This downloads an Ubuntu image on a cold cache and then provisions.\n'
START_TS=$(date +%s)
"$AGENTBOX" create "$CLEAN_REPO"
rc=$?
printf 'create took %s seconds\n' "$(( $(date +%s) - START_TS ))"
if [ "$rc" -eq 0 ]; then ok "agentbox create succeeded"; else bad "agentbox create exited ${rc}"; fi

if "$LIMACTL" list --quiet | grep -qxF "$INSTANCE"; then
    ok "instance ${INSTANCE} exists"
else
    bad "instance ${INSTANCE} does not exist; the remaining guest checks cannot run"
    hr; printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"; hr
    exit 1
fi

"$LIMACTL" list

# ===========================================================================
step "5. isolation checks inside the guest"
# ===========================================================================

printf -- '--- id ---\n'
GUEST_ID=$(guest id 2>/dev/null)
printf '%s\n' "$GUEST_ID"
if printf '%s' "$GUEST_ID" | grep -q 'uid=0('; then
    bad "the guest shell is root"
else
    ok "the guest shell is not root"
fi

printf -- '\n--- /work is writable and shared with the host ---\n'
STAMP="written-by-guest-$(date +%s)"
if guest sh -c "printf '%s\n' '${STAMP}' > /work/guest-wrote-this.txt"; then
    if [ -f "${CLEAN_REPO}/guest-wrote-this.txt" ] && grep -qF "$STAMP" "${CLEAN_REPO}/guest-wrote-this.txt"; then
        ok "a file written in /work appeared on the host"
    else
        bad "the file written in /work did not appear on the host"
    fi
else
    bad "/work is not writable from the guest"
fi

printf -- '\n--- the host home directory is not mounted ---\n'
USERS_OUT=$(guest sh -c 'ls -A /Users 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$USERS_OUT"
if printf '%s' "$USERS_OUT" | grep -q '::rc=0' && [ -n "$(printf '%s' "$USERS_OUT" | sed 's/::rc=.*//' | tr -d '[:space:]')" ]; then
    bad "/Users exists in the guest and is not empty"
else
    ok "/Users is absent or empty in the guest"
fi

printf -- '\n--- the three intended mounts, and only those ---\n'
MNT=$(guest sh -c 'findmnt -t virtiofs -o TARGET,SOURCE,OPTIONS 2>/dev/null || mount | grep -i virtiofs')
printf '%s\n' "$MNT"
for want in /work /opt/agent-box /opt/agent-box-config; do
    if printf '%s' "$MNT" | grep -q -- "$want"; then
        ok "mount present: ${want}"
    else
        bad "mount missing: ${want}"
    fi
done

printf -- '\n--- the agent-box checkout is read-only ---\n'
RO_OUT=$(guest sh -c 'touch /opt/agent-box/should-not-be-writable 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$RO_OUT"
if printf '%s' "$RO_OUT" | grep -q '::rc=0'; then
    bad "/opt/agent-box is writable; it should be read-only"
    rm -f "${BOX_DIR}/should-not-be-writable"
else
    ok "/opt/agent-box is read-only"
fi

printf -- '\n--- the host config mount is read-only ---\n'
ROC_OUT=$(guest sh -c 'touch /opt/agent-box-config/should-not-be-writable 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$ROC_OUT"
if printf '%s' "$ROC_OUT" | grep -q '::rc=0'; then
    bad "/opt/agent-box-config is writable; it should be read-only"
    rm -f "${AGENT_BOX_CONFIG_DIR}/should-not-be-writable"
else
    ok "/opt/agent-box-config is read-only"
fi

printf -- '\n--- the blocklist never reaches the guest ---\n'
# The parent config dir holds the blocklist; only config/guest is mounted.
#
# The probe term is generated at run time. Using the fixed SECRET_TERM would
# report a false positive, because this very file contains that word in its
# source and the checkout is itself one of the mounts being grepped.
BLOCK_PROBE="blockprobe$(date +%s)x$$"
printf '%s\n' "$BLOCK_PROBE" > "$AGENT_BOX_BLOCKLIST"
BL=$(guest sh -c 'ls -la /opt/agent-box-config/ 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$BL"
if guest test -e /opt/agent-box-config/blocklist.txt; then
    bad "/opt/agent-box-config/blocklist.txt exists in the guest"
else
    ok "/opt/agent-box-config/blocklist.txt does not exist in the guest"
fi
# Stronger: the term itself must not be readable anywhere in any mount.
if guest sh -c "grep -rqiF '${BLOCK_PROBE}' /opt/agent-box-config /opt/agent-box /work 2>/dev/null"; then
    bad "the blocklist term is readable somewhere inside the guest"
else
    ok "the blocklist term is not readable in any guest mount"
fi
rm -f "$AGENT_BOX_BLOCKLIST"

printf -- '\n--- the host proxy environment was not copied in ---\n'
# shellcheck disable=SC2016  # must expand in the guest, not on the host.
PROXY_OUT=$(guest sh -c 'echo "http_proxy=${http_proxy:-<unset>} https_proxy=${https_proxy:-<unset>}"' 2>/dev/null)
printf '%s\n' "$PROXY_OUT"
if printf '%s' "$PROXY_OUT" | grep -q 'http_proxy=<unset> https_proxy=<unset>'; then
    ok "no proxy variables in the guest environment"
else
    bad "proxy variables reached the guest environment"
fi

printf -- '\n--- the guest git identity is generic ---\n'
GIT_ID=$(guest sh -c 'git config --get user.name; git config --get user.email' 2>/dev/null)
printf '%s\n' "$GIT_ID"
if printf '%s' "$GIT_ID" | grep -q 'agent-box'; then
    ok "a generic git identity is configured"
else
    bad "no git identity is configured in the guest"
fi

# ===========================================================================
step "6. the egress firewall"
# ===========================================================================

printf -- '--- systemctl is-active agent-box-firewall ---\n'
FW_STATE=$(guest systemctl is-active agent-box-firewall 2>/dev/null)
printf '%s\n' "$FW_STATE"
if [ "$FW_STATE" = "active" ]; then ok "agent-box-firewall is active"; else bad "agent-box-firewall is ${FW_STATE}"; fi

printf -- '\n--- systemctl is-active agent-box-firewall.timer ---\n'
TIMER_STATE=$(guest systemctl is-active agent-box-firewall.timer 2>/dev/null)
printf '%s\n' "$TIMER_STATE"
if [ "$TIMER_STATE" = "active" ]; then ok "the 15-minute refresh timer is active"; else bad "the refresh timer is ${TIMER_STATE}"; fi

printf -- '\n--- agentbox firewall-check ---\n'
FW_OUT="${TMP_ROOT}/firewall.out"
"$AGENTBOX" firewall-check "$CLEAN_REPO" > "$FW_OUT" 2>&1
rc=$?
cat "$FW_OUT"
if [ "$rc" -eq 0 ]; then ok "firewall-check exited 0"; else bad "firewall-check exited ${rc}"; fi
for check in policy-drop policy-drop-v6 allowlist-rule literal-ip-denied foreign-dns-denied egress-denied anthropic-allowed github-allowed; do
    if grep -q "^PASS  ${check}" "$FW_OUT"; then
        ok "firewall check ${check}"
    else
        bad "firewall check ${check}"
    fi
done

printf -- '\n--- the ruleset, as applied ---\n'
guest sudo iptables -S 2>/dev/null
printf -- '\n--- ip6tables policies ---\n'
V6=$(guest sudo ip6tables -S 2>/dev/null | grep '^-P')
printf '%s\n' "$V6"
if printf '%s' "$V6" | grep -qx -- '-P OUTPUT DROP'; then
    ok "ip6tables OUTPUT policy is DROP"
else
    bad "ip6tables OUTPUT policy is not DROP"
fi

printf -- '\n--- a non-allowlisted host by name is refused ---\n'
BLOCKED=$(guest sh -c 'curl -sS -m 5 -o /dev/null https://example.com 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$BLOCKED"
if printf '%s' "$BLOCKED" | grep -q '::rc=0'; then
    bad "example.com was reachable"
else
    ok "example.com was refused"
fi

printf -- '\n--- a non-allowlisted host by literal address is refused ---\n'
LIT=$(guest sh -c 'curl -sS -m 5 -o /dev/null https://198.51.100.42/ 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$LIT"
if printf '%s' "$LIT" | grep -q '::rc=0'; then
    bad "a literal non-allowlisted address was reachable"
else
    ok "a literal non-allowlisted address was refused"
fi

printf -- '\n--- DNS to a foreign resolver is refused ---\n'
# dig's own exit status, not a pipeline's: `dig | tail` would report tail's.
FDNS=$(guest sh -c 'dig +time=2 +tries=1 @9.9.9.9 example.com 2>&1; printf "::rc=%s" "$?"' 2>/dev/null | tail -4)
printf '%s\n' "$FDNS"
if printf '%s' "$FDNS" | grep -q '::rc=0'; then
    bad "DNS to 9.9.9.9 succeeded"
else
    ok "DNS to 9.9.9.9 was refused"
fi

# ===========================================================================
step "7. Claude Code, the environment, and verify-auth"
# ===========================================================================

printf -- '--- claude --version (login shell) ---\n'
VER_OUT=$("$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -lc 'claude --version' 2>&1)
printf '%s\n' "$VER_OUT"
if printf '%s' "$VER_OUT" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
    ok "claude --version printed a version"
else
    bad "claude --version did not print a version"
fi

printf -- '\n--- the guest environment ---\n'
# shellcheck disable=SC2016  # these must expand in the guest, not on the host.
guest sh -c 'echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}"; echo "DISABLE_TELEMETRY=${DISABLE_TELEMETRY:-<unset>}"; echo "DISABLE_ERROR_REPORTING=${DISABLE_ERROR_REPORTING:-<unset>}"; echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:+<set>}${ANTHROPIC_API_KEY:-<unset>}"'

printf -- '\n--- verify-auth refuses cleanly with no token ---\n'
VA_OUT="${TMP_ROOT}/verify-auth.out"
"$AGENTBOX" verify-auth "$CLEAN_REPO" > "$VA_OUT" 2>&1
rc=$?
cat "$VA_OUT"
if [ "$rc" -ne 0 ]; then ok "verify-auth exited non-zero without a token"; else bad "verify-auth exited 0 without a token"; fi
if grep -q 'no token at' "$VA_OUT"; then
    ok "verify-auth named the missing token as the reason"
else
    bad "verify-auth did not name the missing token"
fi
if grep -qi 'browser\|log in' "$VA_OUT"; then
    bad "verify-auth fell through to an interactive login"
else
    ok "verify-auth did not fall through to an interactive login"
fi

printf -- '\n--- limactl shell does not allocate a pty for piped stdin ---\n'
# The token subcommand relies on this: with a pty, the guest would echo the
# pasted token back onto the host terminal and into scrollback.
TTY_OUT=$(printf 'x' | "$LIMACTL" shell --workdir /work "$INSTANCE" -- tty 2>&1)
printf '%s\n' "$TTY_OUT"
if printf '%s' "$TTY_OUT" | grep -qi 'not a tty'; then
    ok "no pty is allocated when stdin is a pipe"
else
    bad "a pty was allocated for piped stdin; the token could be echoed"
fi

# ===========================================================================
step "7b. personal config carry-over, plugins, and the interactive subcommand"
# ===========================================================================
#
# Everything staged in step 3d, checked from inside the guest. The plugin
# install ran during provisioning, after the firewall came up, so it is also a
# live test of the GitHub range rule.

printf -- '--- python3 is present (the config sync and the plugin checks need it) ---\n'
PY_OUT=$(guest python3 --version 2>&1)
printf '%s\n' "$PY_OUT"
if printf '%s' "$PY_OUT" | grep -qE 'Python 3\.[0-9]+'; then
    ok "python3 is present in the guest"
else
    bad "python3 is not present in the guest"
fi

printf -- '\n--- the carried-over CLAUDE.md and governor.json ---\n'
CARRY_OUT="${TMP_ROOT}/carry.out"
guest bash -l > "$CARRY_OUT" 2>&1 <<'SH'
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR}"
echo "--- CLAUDE.md ---"
cat "${CLAUDE_CONFIG_DIR}/CLAUDE.md" 2>&1
echo "--- listing ---"
ls -A "${CLAUDE_CONFIG_DIR}" 2>&1
echo "--- rules ---"
ls -A "${CLAUDE_CONFIG_DIR}/rules" 2>&1
echo "--- settings.json as installed ---"
cat "${CLAUDE_CONFIG_DIR}/settings.json" 2>&1
for f in governor.json rules/smoke.md; do
    if [ -f "${CLAUDE_CONFIG_DIR}/${f}" ]; then echo "PRESENT ${f}"; else echo "MISSING ${f}"; fi
done
if [ -e "${CLAUDE_CONFIG_DIR}/.credentials.json" ]; then
    echo "CRED-PRESENT"
else
    echo "CRED-ABSENT"
fi
SH
cat "$CARRY_OUT"

if grep -qF "$CLAUDE_MARKER" "$CARRY_OUT"; then
    ok "the host CLAUDE.md was carried into the guest config directory"
else
    bad "the host CLAUDE.md did not reach the guest config directory"
fi
if grep -qx 'PRESENT governor.json' "$CARRY_OUT"; then
    ok "governor.json was carried over"
else
    bad "governor.json was not carried over"
fi
if grep -qx 'PRESENT rules/smoke.md' "$CARRY_OUT"; then
    ok "rules/*.md were carried over"
else
    bad "rules/*.md were not carried over"
fi
if grep -qx 'CRED-ABSENT' "$CARRY_OUT"; then
    ok "the staged .credentials.json was NOT copied into the guest"
else
    bad "a .credentials.json reached the guest config directory"
fi

# settings.json crosses, but filtered. A name-based allowlist cannot see inside
# a file, and this file's `env` block is a credential.
if grep -q "\"${SETTINGS_HARMLESS_KEY}\"" "$CARRY_OUT"; then
    ok "the harmless settings.json key survived the crossing"
else
    bad "the harmless settings.json key did not survive the crossing"
fi
if grep -q '"env"' "$CARRY_OUT"; then
    bad "the settings.json env block reached the guest"
else
    ok "the settings.json env block did NOT reach the guest"
fi
if grep -q '"apiKeyHelper"' "$CARRY_OUT"; then
    bad "the settings.json apiKeyHelper reached the guest"
else
    ok "the settings.json apiKeyHelper did NOT reach the guest"
fi
if grep -qF "$SETTINGS_FAKE_KEY" "$CARRY_OUT"; then
    bad "the fake API key from settings.json reached the guest"
else
    ok "the fake API key from settings.json did NOT reach the guest"
fi

printf -- '\n--- the refusal and the stripping are logged, not silent ---\n'
SYNC_OUT="${TMP_ROOT}/sync.out"
guest /opt/agent-box/guest/sync-claude-config.sh > "$SYNC_OUT" 2>&1
rc=$?
cat "$SYNC_OUT"
if [ "$rc" -eq 0 ]; then ok "sync-claude-config exited 0 on a second run (idempotent)"; else bad "sync-claude-config exited ${rc} on a second run"; fi
if grep -q 'REFUSED .credentials.json' "$SYNC_OUT"; then
    ok "the refusal of .credentials.json was reported"
else
    bad "the refusal of .credentials.json was not reported"
fi
if grep -q 'STRIPPED settings.json:env' "$SYNC_OUT" && grep -q 'STRIPPED settings.json:apiKeyHelper' "$SYNC_OUT"; then
    ok "each stripped settings.json key was named"
else
    bad "the stripped settings.json keys were not named"
fi

printf -- '\n--- a settings.json edited inside the guest cannot smuggle a key past the precondition ---\n'
# The filter above covers the file that crosses the mount. This covers the
# other way in: a settings.json written directly inside the guest. Without the
# check in lib.sh, `env.ANTHROPIC_API_KEY` would be injected by the CLI after
# abx_assert_environment had already approved the shell environment, and the
# run would bill an API account instead of the subscription. A token is planted
# too, so the refusal cannot be the "no token" one.
#
# agent-run.sh is invoked directly rather than through `agentbox run`, because
# the host command re-syncs the config first and would repair the poisoned file
# before the guest ever saw it. Bypassing that is the point: the guard has to
# hold on the file as it stands, not only on the file as the mount supplies it.
POISON_OUT="${TMP_ROOT}/poisoned-settings.out"
POISON_TOKEN="sk-ant-oat01-POISONHEADzzzzzzzzzzzzzzzzPOISONTAIL"
guest bash -l <<SH
umask 077
printf '%s' '${POISON_TOKEN}' > "\$HOME/.config/agent-box/token"
chmod 600 "\$HOME/.config/agent-box/token"
cp "\${CLAUDE_CONFIG_DIR}/settings.json" /tmp/settings.json.smokebak
printf '{"env":{"ANTHROPIC_API_KEY":"%s"}}\n' '${SETTINGS_FAKE_KEY}' > "\${CLAUDE_CONFIG_DIR}/settings.json"
SH
printf 'Do nothing.\n' | "$LIMACTL" shell --workdir /work "$INSTANCE" -- \
    /opt/agent-box/guest/agent-run.sh --slug poison --brief - > "$POISON_OUT" 2>&1
poison_rc=$?
cat "$POISON_OUT"
if [ "$poison_rc" -ne 0 ]; then
    ok "agent-run refused while settings.json carried a credential"
else
    bad "agent-run proceeded with a credential-bearing settings.json"
fi
if [ -d "${CLEAN_REPO}/.agent-box" ] || git -C "$CLEAN_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null | grep -q '^agent/poison'; then
    bad "agent-run changed something before refusing over settings.json"
else
    ok "agent-run changed nothing before refusing over settings.json"
fi
if grep -q 'credential-bearing keys' "$POISON_OUT" && grep -q 'settings.json' "$POISON_OUT"; then
    ok "the refusal named settings.json and the key"
else
    bad "the refusal did not name settings.json"
fi
if grep -qF "$SETTINGS_FAKE_KEY" "$POISON_OUT"; then
    bad "the refusal echoed the key's value"
else
    ok "the refusal did not echo the key's value"
fi
# Put the guest back the way it was: the filtered settings.json, no token.
# shellcheck disable=SC2016  # must expand in the guest, not on the host.
guest bash -l -c 'mv -f /tmp/settings.json.smokebak "${CLAUDE_CONFIG_DIR}/settings.json"; rm -f "$HOME/.config/agent-box/token"'

printf -- '\n--- /work is marked as a trusted folder ---\n'
TRUST_OUT="${TMP_ROOT}/trust.out"
guest bash -l > "$TRUST_OUT" 2>&1 <<'SH'
jq -r --arg p /work '.projects[$p].hasTrustDialogAccepted' "${CLAUDE_CONFIG_DIR}/.claude.json"
SH
cat "$TRUST_OUT"
if grep -qx 'true' "$TRUST_OUT"; then
    ok 'projects["/work"].hasTrustDialogAccepted is true'
else
    bad 'projects["/work"].hasTrustDialogAccepted is not true'
fi

printf -- '\n--- DISABLE_AUTOUPDATER in the login environment ---\n'
# shellcheck disable=SC2016  # must expand in the guest, not on the host.
AU_OUT=$(guest bash -lc 'echo "DISABLE_AUTOUPDATER=${DISABLE_AUTOUPDATER:-<unset>}"' 2>&1)
printf '%s\n' "$AU_OUT"
if printf '%s' "$AU_OUT" | grep -qx 'DISABLE_AUTOUPDATER=1'; then
    ok "DISABLE_AUTOUPDATER=1 in the login environment"
else
    bad "DISABLE_AUTOUPDATER is not 1 in the login environment"
fi

printf -- '\n--- agentbox plugins: the on-demand path, and whether it needs an account ---\n'
PLUG_OUT="${TMP_ROOT}/plugins.out"
run_bounded 300 "$PLUG_OUT" "$AGENTBOX" plugins "$CLEAN_REPO"
plug_rc=$BOUNDED_RC
cat "$PLUG_OUT"
printf 'agentbox plugins exit status: %s\n' "$plug_rc"

printf -- '\n--- claude plugin marketplace list / claude plugin list ---\n'
PLIST_OUT="${TMP_ROOT}/plugin-list.out"
MK_OUT="${TMP_ROOT}/marketplace-list.out"
INST_OUT="${TMP_ROOT}/installed-list.out"
guest bash -l > "$MK_OUT" 2>&1 <<'SH'
claude plugin marketplace list 2>&1
SH
guest bash -l > "$INST_OUT" 2>&1 <<'SH'
claude plugin list 2>&1
SH
{ printf -- '--- marketplaces ---\n'; cat "$MK_OUT"; printf -- '--- installed ---\n'; cat "$INST_OUT"; } | tee "$PLIST_OUT"

# One of two things is true, and the point of the step is to record which.
# Either an explicit CLI install works with no account in the VM, or it does
# not and the documented fallback is what the operator sees.
#
# The installed check asserts the full identity, `governor@konyklabs-plugins`,
# against the installed listing alone. A bare `governor` would also match the
# marketplace listing, and a plugin of that name from some other marketplace.
if grep -q "$MARKETPLACE_NAME" "$MK_OUT" && grep -q "${PLUGIN_UNDER_TEST}@${MARKETPLACE_NAME}" "$INST_OUT"; then
    ok "PLUGIN PATH: install needs NO account — ${MARKETPLACE_NAME} is registered and ${PLUGIN_UNDER_TEST} is installed"
    if [ "$plug_rc" -eq 0 ]; then
        ok "agentbox plugins exited 0 on an already-satisfied plugins.txt"
    else
        bad "agentbox plugins exited ${plug_rc} although the plugin is installed"
    fi
    # Installed is not the same as usable. `claude plugin install` records the
    # enable in settings.json, which is the very file the config sync carries
    # over — so a sync that copied it wholesale would disable every plugin the
    # guest had just installed, and the listing above would still say it was
    # installed. That is the failure this line exists to catch.
    if grep -q 'disabled' "$INST_OUT"; then
        bad "${PLUGIN_UNDER_TEST} is installed but DISABLED — the config sync clobbered enabledPlugins"
    else
        ok "${PLUGIN_UNDER_TEST} survived the config sync still enabled"
    fi
elif [ "$plug_rc" -eq 4 ] && grep -q 'would not install plugins without an account' "$PLUG_OUT"; then
    ok "PLUGIN PATH: install NEEDS an account — the documented fallback was printed and the exit status was 4"
    if grep -q 'agentbox plugins <repo>' "$PLUG_OUT"; then
        ok "the fallback names 'agentbox plugins' as the next step"
    else
        bad "the fallback does not name the next step"
    fi
else
    bad "neither plugin path held: exit ${plug_rc}, and the listings show neither the marketplace nor the fallback"
fi

printf -- '\n--- a session-only plugin from the read-only config mount ---\n'
DEMO_OUT="${TMP_ROOT}/demo-plugin.out"
guest bash -l > "$DEMO_OUT" 2>&1 <<'SH'
claude --plugin-dir /opt/agent-box-config/plugin-dir/demo plugin list 2>&1
SH
cat "$DEMO_OUT"
# `demo@inline` is the identity the CLI prints for a --plugin-dir plugin, and
# it prints it only under Session-only plugins. A bare `demo` would also match
# the directory path in the `Path:` line, which the CLI prints whether or not
# the plugin loaded.
if grep -q 'demo@inline' "$DEMO_OUT"; then
    ok "--plugin-dir loaded demo from the read-only host config mount"
else
    bad "--plugin-dir did not load demo"
fi
if grep -qE 'Status:.*(loaded|enabled)' "$DEMO_OUT"; then
    ok "the CLI reported the session plugin as loaded, not merely listed"
else
    bad "the CLI did not report the session plugin as loaded"
fi

printf -- '\n--- agentbox claude refuses cleanly with no token ---\n'
AC_OUT="${TMP_ROOT}/agentbox-claude.out"
run_bounded 60 "$AC_OUT" "$AGENTBOX" claude "$CLEAN_REPO" --version
ac_rc=$BOUNDED_RC
cat "$AC_OUT"
if [ "$ac_rc" -ne 0 ]; then ok "agentbox claude exited non-zero without a token"; else bad "agentbox claude exited 0 without a token"; fi
if grep -q 'no token at' "$AC_OUT"; then
    ok "agentbox claude named the missing token as the reason"
else
    bad "agentbox claude did not name the missing token"
fi
if grep -qi 'browser\|log in' "$AC_OUT"; then
    bad "agentbox claude fell through to an interactive login"
else
    ok "agentbox claude did not fall through to an interactive login"
fi

printf -- '\n--- agentbox update reports a version either side of the update ---\n'
UP_OUT="${TMP_ROOT}/update.out"
run_bounded 300 "$UP_OUT" "$AGENTBOX" update "$CLEAN_REPO"
up_rc=$BOUNDED_RC
cat "$UP_OUT"
if [ "$up_rc" -eq 0 ]; then ok "agentbox update exited 0"; else bad "agentbox update exited ${up_rc}"; fi
if grep -qE '^agentbox: before: .*[0-9]+\.[0-9]+\.[0-9]+' "$UP_OUT" && grep -qE '^agentbox: after: +.*[0-9]+\.[0-9]+\.[0-9]+' "$UP_OUT"; then
    ok "agentbox update printed the version before and after"
else
    bad "agentbox update did not print both versions"
fi

# ===========================================================================
step "7c. install-plugins rejects a bad directive and bounds its CLI calls"
# ===========================================================================
#
# Both paths need a plugins.txt other than the one on the read-only mount, so
# they use AGENT_BOX_CONFIG_DIR to point the script at a writable directory in
# the guest. Neither can be exercised on the host: the script needs bash 4's
# mapfile and coreutils `timeout`, and this Mac has bash 3.2 and neither.

printf -- '--- a directive argument that starts with a dash is refused ---\n'
DASH_OUT="${TMP_ROOT}/plugins-dash.out"
guest bash -l > "$DASH_OUT" 2>&1 <<'SH'
rm -rf /tmp/abx-badcfg
mkdir -p /tmp/abx-badcfg
printf 'marketplace --help\n' > /tmp/abx-badcfg/plugins.txt
AGENT_BOX_CONFIG_DIR=/tmp/abx-badcfg /opt/agent-box/guest/install-plugins.sh
echo "RC=$?"
SH
cat "$DASH_OUT"
guest sh -c 'rm -rf /tmp/abx-badcfg'
if grep -q 'RC=2' "$DASH_OUT"; then
    ok "a malformed directive exited 2"
else
    bad "a malformed directive did not exit 2"
fi
if grep -q "must not start with '-'" "$DASH_OUT"; then
    ok "a leading-dash argument was refused by name"
else
    bad "a leading-dash argument was not refused"
fi
if grep -q 'marketplace add --help: ok' "$DASH_OUT"; then
    bad "the CLI was invoked with the dash argument as a flag"
else
    ok "the CLI was never invoked with the dash argument"
fi

printf -- '\n--- a CLI call that never answers is bounded and reported as unreachable ---\n'
# A stub `claude` that hangs, reached through a temporary HOME because the
# script prepends "$HOME/.local/bin" to PATH. This reproduces the shape of an
# unresponsive marketplace exactly, with no dependency on the network being
# broken at the time.
HANG_OUT="${TMP_ROOT}/plugins-hang.out"
run_bounded 90 "$HANG_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -l -c '
rm -rf /tmp/abx-hang
mkdir -p /tmp/abx-hang/.local/bin /tmp/abx-hang/cfg
printf "#!/bin/sh\nsleep 300\n" > /tmp/abx-hang/.local/bin/claude
chmod +x /tmp/abx-hang/.local/bin/claude
printf "marketplace someone/never-answers\n" > /tmp/abx-hang/cfg/plugins.txt
HOME=/tmp/abx-hang AGENT_BOX_CONFIG_DIR=/tmp/abx-hang/cfg ABX_CLI_TIMEOUT=3 \
    /opt/agent-box/guest/install-plugins.sh
echo "RC=$?"
'
cat "$HANG_OUT"
guest sh -c 'rm -rf /tmp/abx-hang'
if grep -q 'RC=5' "$HANG_OUT"; then
    ok "an unanswering CLI call exited 5, the unreachable-marketplace status"
else
    bad "an unanswering CLI call did not exit 5"
fi
if grep -q 'the marketplace is unreachable' "$HANG_OUT"; then
    ok "the timeout was reported as an unreachable marketplace"
else
    bad "the timeout was not reported as an unreachable marketplace"
fi
if grep -q 'firewall-check' "$HANG_OUT"; then
    ok "the unreachable message names the next thing to run"
else
    bad "the unreachable message does not name a next step"
fi

# ===========================================================================
step "8. agent-run refuses to start without a token"
# ===========================================================================

# --wait, because these four checks are about the exit status and the message
# reaching the caller. Runs are detached by default now, so the plain form
# returns 0 with the run still starting; the detached path is the next step.
RUN_OUT="${TMP_ROOT}/run.out"
printf 'Do nothing.\n' > "${TMP_ROOT}/noop-brief.md"
run_bounded 240 "$RUN_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md" --wait
rc=$BOUNDED_RC
cat "$RUN_OUT"
if [ "$rc" -ne 0 ]; then ok "agent-run exited non-zero without a token"; else bad "agent-run exited 0 without a token"; fi
if grep -q 'no token at' "$RUN_OUT"; then
    ok "agent-run explained that the token is missing"
else
    bad "agent-run did not name the missing token as the reason"
fi
if [ -d "${CLEAN_REPO}/.agent-box" ]; then
    bad "agent-run created state despite refusing to run"
else
    ok "agent-run changed nothing before refusing"
fi

# ===========================================================================
step "8a. a DETACHED run without a token fails fast, and says so afterwards"
# ===========================================================================
#
# The default shape: `run` returns as soon as the task has started, and the
# record of what happened is read back with `runs` and `logs`. A run that dies
# in its preconditions has no terminal to have printed on, so this is the only
# way that failure is ever seen.

DET_OUT="${TMP_ROOT}/detached.out"
run_bounded 90 "$DET_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md"
det_rc=$BOUNDED_RC
cat "$DET_OUT"
if [ "$det_rc" -eq 0 ]; then ok "a detached run returned 0 immediately"; else bad "a detached run exited ${det_rc}"; fi

DET_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$DET_OUT" | head -1)
printf 'detached runid: %s\n' "${DET_RUNID:-<none>}"
if [ -n "$DET_RUNID" ]; then ok "the run id was printed"; else bad "no run id was printed"; fi

# It fails in its preconditions, so it is over in seconds; poll rather than
# assume.
DET_STATE=""
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    DET_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$DET_RUNID" 2>/dev/null | tr -d '\r\n')
    case "$DET_STATE" in running|"") sleep 2 ;; *) break ;; esac
done
printf 'state: %s\n' "$DET_STATE"

DET_RUNS="${TMP_ROOT}/detached-runs.out"
"$AGENTBOX" runs "$CLEAN_REPO" > "$DET_RUNS" 2>&1
cat "$DET_RUNS"
if grep -q "$DET_RUNID" "$DET_RUNS" && grep -qE "${DET_RUNID}.*failed" "$DET_RUNS"; then
    ok "runs lists the detached run as failed"
else
    bad "runs does not list the detached run as failed"
fi
case "$DET_STATE" in
    exit:0)  bad "the tokenless run recorded exit:0" ;;
    exit:*)  ok "the run recorded a non-zero exit (${DET_STATE})" ;;
    *)       bad "the run never left state '${DET_STATE}'" ;;
esac

DET_LOGS="${TMP_ROOT}/detached-logs.out"
run_bounded 60 "$DET_LOGS" "$AGENTBOX" logs "$CLEAN_REPO" "$DET_RUNID"
cat "$DET_LOGS"
if grep -q 'no token at' "$DET_LOGS"; then
    ok "logs shows the reason the detached run failed"
else
    bad "logs does not show why the detached run failed"
fi

# ===========================================================================
step "8b. the token leak check fires and exits 3"
# ===========================================================================
#
# The check must catch the token reaching the host's disk. It runs after a real
# `claude -p` call, so a fake token is planted first: the call will fail
# authentication, which is fine — the leak check runs regardless, and what is
# being tested is that a hit reaches the caller as exit 3 rather than being lost
# in a subshell.

FAKE_TOKEN="sk-ant-oat01-SMOKEHEADzzzzzzzzzzzzzzzzzzzzSMOKETAIL"
guest sh -c "umask 077; printf '%s' '${FAKE_TOKEN}' > \$HOME/.config/agent-box/token; chmod 600 \$HOME/.config/agent-box/token"
if guest sh -c 'test -d /work/.git'; then
    ok "the work repo is present in the guest"
else
    bad "the work repo is missing in the guest"
fi

# A tracked file, so that the planted token shows up in `git diff` — which is
# one of the streams the check reads.
guest sh -c 'cd /work && git add -A && git commit -q -m "smoke base" 2>&1 | tail -1; true'
guest sh -c "cd /work && printf 'leaked: %s\\n' '${FAKE_TOKEN}' >> hello.txt"
printf -- '--- git diff in the guest now carries the fake token ---\n'
guest sh -c 'cd /work && git diff --stat'

LEAK_OUT="${TMP_ROOT}/leak.out"
run_bounded 300 "$LEAK_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md" --wait
leak_rc=$BOUNDED_RC
cat "$LEAK_OUT"
printf 'agentbox run exit status: %s\n' "$leak_rc"

if [ "$leak_rc" -eq 3 ]; then
    ok "agent-run exited 3 when the token appeared in output reaching the host"
else
    bad "agent-run exited ${leak_rc}; expected 3 for a token leak"
fi
# The report has two halves now. `logs` refuses a leak-flagged run's events, so
# what --wait shows is the banner; the line naming the stream is in the output
# the banner is withholding, and --force-unsafe is how you get it.
if grep -q 'leak check found the OAuth token' "$LEAK_OUT"; then
    ok "the leak was reported to the operator, with what to do about it"
else
    bad "the leak was not reported"
fi
LEAK_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$LEAK_OUT" | head -1)
if [ -n "$LEAK_RUNID" ]; then
    LEAK_FORCED="${TMP_ROOT}/leak-forced.out"
    run_bounded 60 "$LEAK_FORCED" "$AGENTBOX" logs "$CLEAN_REPO" "$LEAK_RUNID" --force-unsafe
    if grep -q 'SECURITY: the token appears in' "$LEAK_FORCED"; then
        ok "--force-unsafe shows the leak report, naming the stream"
    else
        bad "--force-unsafe did not show the leak report"
    fi
    if grep -qF "$FAKE_TOKEN" "$LEAK_FORCED"; then
        bad "--force-unsafe echoed the token value"
    else
        ok "--force-unsafe still did not echo the token value"
    fi
else
    bad "could not read the leaking run's id back"
fi
if grep -qF "$FAKE_TOKEN" "$LEAK_OUT"; then
    bad "the token value itself was echoed by the leak report"
else
    ok "the leak report did not echo the token value"
fi

printf -- '\n--- clean up the planted token and the modified file ---\n'
# shellcheck disable=SC2016  # $HOME must expand in the guest, not on the host.
guest sh -c 'rm -f $HOME/.config/agent-box/token'
guest sh -c 'cd /work && git checkout -- . 2>/dev/null; true'
# shellcheck disable=SC2016  # $HOME must expand in the guest, not on the host.
guest sh -c 'rm -rf /work/.agent-box $HOME/.agent-box/runs' || true

# The planted token must be gone from the work tree, or step 9's preflight will
# legitimately refuse to start the VM.
if grep -rqF "$FAKE_TOKEN" "$CLEAN_REPO" 2>/dev/null; then
    bad "the planted token is still in the work tree on the host"
else
    ok "the planted token is gone from the work tree"
fi

# ===========================================================================
step "8d. a detached run that reaches the CLI: the run directory, runs, logs"
# ===========================================================================
#
# With a fake token in place the run gets all the way to a real `claude` call
# and fails authentication. That is the interesting case for the sensors: there
# is a run directory, an event stream, a status, and a formatted log — and none
# of it may carry a fragment of the token.

guest sh -c "umask 077; printf '%s' '${FAKE_TOKEN}' > \$HOME/.config/agent-box/token; chmod 600 \$HOME/.config/agent-box/token"

AUTH_OUT="${TMP_ROOT}/authfail.out"
run_bounded 90 "$AUTH_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md"
cat "$AUTH_OUT"
AUTH_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$AUTH_OUT" | head -1)
printf 'runid: %s\n' "${AUTH_RUNID:-<none>}"
if [ -n "$AUTH_RUNID" ]; then
    ok "the fake-token run started and printed its id"
else
    # Not a fabricated id: `logs` for one that does not exist returns fast and
    # non-zero, which would make every assertion below report a pass for a run
    # that never happened.
    bad "the fake-token run printed no id; skipping the checks that depend on it"
    hr; printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"; hr
    exit 1
fi

# `logs -f` must come back on its own when the run ends. Started here, while
# the run is still going, which is the only way that claim means anything.
FOLLOW_OUT="${TMP_ROOT}/logs-follow.out"
FOLLOW_T0=$(date +%s)
run_bounded 300 "$FOLLOW_OUT" "$AGENTBOX" logs "$CLEAN_REPO" "$AUTH_RUNID" -f
follow_rc=$BOUNDED_RC
FOLLOW_ELAPSED=$(( $(date +%s) - FOLLOW_T0 ))
cat "$FOLLOW_OUT"
printf 'logs -f returned after %ss with status %s\n' "$FOLLOW_ELAPSED" "$follow_rc"
# Exit 0, not merely "not killed". A `logs` that failed instantly — a run id
# that does not exist, an instance that stopped answering — also returns
# non-124, and would report a pass for something that never followed anything.
if [ "$follow_rc" -eq 0 ]; then
    ok "logs -f returned on its own, with exit 0, when the run ended"
else
    bad "logs -f exited ${follow_rc}; it did not follow the run to its end"
fi
if grep -qE '^[0-9]{2}:[0-9]{2}:[0-9]{2}  status  exit:' "$FOLLOW_OUT"; then
    ok "logs -f ended with the run's status line"
else
    bad "logs -f did not print the run's status line"
fi

printf -- '\n--- the run directory as it stands in the guest ---\n'
RUNDIR_OUT="${TMP_ROOT}/rundir.out"
guest sh -c "ls -la \$HOME/.agent-box/runs/${AUTH_RUNID}" > "$RUNDIR_OUT" 2>&1
cat "$RUNDIR_OUT"
for f in meta.json events.jsonl status console.log hooks.jsonl summary.txt; do
    if grep -q " ${f}\$" "$RUNDIR_OUT"; then
        ok "the run directory has ${f}"
    else
        bad "the run directory is missing ${f}"
    fi
done
printf -- '\n--- meta.json ---\n'
guest sh -c "cat \$HOME/.agent-box/runs/${AUTH_RUNID}/meta.json" 2>&1

printf -- '\n--- runs --json, in the form a caller assembling a command line uses ---\n'
# `--` before the operands. A caller that did not type the path cannot know
# whether it begins with a dash, and this is the only way it can say so.
RUNSJ="${TMP_ROOT}/runs.json"
"$AGENTBOX" runs --json -- "$CLEAN_REPO" > "$RUNSJ" 2>&1
cat "$RUNSJ"
if jq -e . "$RUNSJ" >/dev/null 2>&1; then
    ok "runs --json -- <repo> works with the operand after a double dash"
else
    bad "runs --json -- <repo> did not produce JSON"
fi
if jq -e . "$RUNSJ" >/dev/null 2>&1; then
    ok "runs --json parses"
else
    bad "runs --json does not parse"
fi
if jq -e --arg r "$AUTH_RUNID" 'map(select(.runid == $r and .state == "failed")) | length == 1' "$RUNSJ" >/dev/null 2>&1; then
    ok "runs --json lists the run with state failed"
else
    bad "runs --json does not list the run as failed"
fi
if jq -e --arg r "$AUTH_RUNID" 'map(select(.runid == $r))[0] | has("exit_code") and has("model") and has("branch") and has("started_at") and has("duration_s") and has("turns") and has("cost_usd") and has("files_changed")' "$RUNSJ" >/dev/null 2>&1; then
    ok "runs --json carries every documented key"
else
    bad "runs --json is missing documented keys"
fi

printf -- '\n--- logs, formatted ---\n'
LOGS_OUT="${TMP_ROOT}/logs.out"
run_bounded 90 "$LOGS_OUT" "$AGENTBOX" logs "$CLEAN_REPO" "$AUTH_RUNID"
cat "$LOGS_OUT"
if grep -qE '^[0-9]{2}:[0-9]{2}:[0-9]{2}  (status|text|tool|out|hook|result) ' "$LOGS_OUT"; then
    ok "logs printed formatted event lines"
else
    bad "logs printed no formatted event lines"
fi
FAKE_HEAD=${FAKE_TOKEN:0:8}
FAKE_TAIL=${FAKE_TOKEN: -8}
if grep -qF "$FAKE_HEAD" "$LOGS_OUT" || grep -qF "$FAKE_TAIL" "$LOGS_OUT"; then
    bad "logs printed a fragment of the token"
else
    ok "logs printed neither the token's head nor its tail"
fi

printf -- '\n--- logs --json ---\n'
LOGSJ="${TMP_ROOT}/logs.json"
run_bounded 90 "$LOGSJ" "$AGENTBOX" logs "$CLEAN_REPO" "$AUTH_RUNID" --json
head -5 "$LOGSJ"
LOGSJ_BAD=0
LOGSJ_LINES=0
while IFS= read -r jline; do
    [ -n "$jline" ] || continue
    LOGSJ_LINES=$((LOGSJ_LINES + 1))
    printf '%s' "$jline" | jq -e 'has("ts") and has("run") and has("kind") and has("text") and has("tool") and has("detail")' >/dev/null 2>&1 \
        || LOGSJ_BAD=$((LOGSJ_BAD + 1))
done < "$LOGSJ"
printf '%s lines, %s malformed\n' "$LOGSJ_LINES" "$LOGSJ_BAD"
if [ "$LOGSJ_LINES" -gt 0 ] && [ "$LOGSJ_BAD" -eq 0 ]; then
    ok "every logs --json line parses and carries the required keys"
else
    bad "logs --json produced ${LOGSJ_LINES} lines with ${LOGSJ_BAD} malformed"
fi
if grep -qF "$FAKE_HEAD" "$LOGSJ" || grep -qF "$FAKE_TAIL" "$LOGSJ"; then
    bad "logs --json printed a fragment of the token"
else
    ok "logs --json printed neither the token's head nor its tail"
fi

# ===========================================================================
step "8e. hook-event.sh turns one hook payload into one line"
# ===========================================================================

HOOK_OUT="${TMP_ROOT}/hook-event.out"
guest bash -l > "$HOOK_OUT" 2>&1 <<'SH'
set -u
# Inside the state root: hook-event.sh refuses any destination outside it, and
# a mktemp -d under /tmp is exactly the case it refuses.
d="$HOME/.agent-box/sessions/hooktest"
rm -rf "$d"; mkdir -p "$d"
printf '%s' '{"session_id":"abc123","cwd":"/work","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/work/src/x.py","old_string":"a"}}' \
    | AGENT_BOX_EVENTS_DIR="$d" /opt/agent-box/guest/hook-event.sh
echo "RC=$?"
echo "--- hooks.jsonl ---"
cat "$d/hooks.jsonl"
echo "--- fields ---"
jq -r '"event=\(.event) tool=\(.tool) input_head=\(.input_head) session=\(.session_id) ok=\(.ok)"' "$d/hooks.jsonl"
echo "--- with no events dir, it writes nothing and exits 0 ---"
printf '%s' '{"hook_event_name":"Stop"}' | /opt/agent-box/guest/hook-event.sh
echo "RC_NODIR=$?"
rm -rf "$d"
SH
cat "$HOOK_OUT"
if grep -q '^RC=0' "$HOOK_OUT"; then ok "hook-event.sh exited 0"; else bad "hook-event.sh did not exit 0"; fi
if grep -q 'event=PreToolUse tool=Edit input_head=/work/src/x.py session=abc123 ok=null' "$HOOK_OUT"; then
    ok "the hook line carries the expected fields"
else
    bad "the hook line does not carry the expected fields"
fi
if grep -q '^RC_NODIR=0' "$HOOK_OUT"; then
    ok "hook-event.sh exits 0 with no events directory"
else
    bad "hook-event.sh did not exit 0 with no events directory"
fi

# ===========================================================================
step "8f. stop-run: it signals, it observes, and it refuses what it should"
# ===========================================================================
#
# The stand-in traps INT and writes a marker, so the assertion can distinguish
# "the process was interrupted" from "cmd_stop wrote a status file". With an
# unconditional write and a stand-in that ignores signals, this step used to
# pass even if nothing was ever signalled.

STANDIN=20260101-000000
guest bash -l > "${TMP_ROOT}/standin.out" 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${STANDIN}"
rm -rf "\$d"; mkdir -p "\$d"; chmod 700 "\$d"
printf 'running\n' > "\$d/status"
printf '{"runid":"${STANDIN}","model":"sonnet","branch":null,"brief":"stand-in","started_at":"2026-01-01T00:00:00Z","tmux":"run-${STANDIN}","max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
rm -f /tmp/abx-standin-interrupted
cat > /tmp/abx-standin.sh <<'INNER'
#!/bin/bash
# Loops, so that killing the inner sleep is not enough to end it. Only SIGINT
# to this process writes the marker — which is what makes the assertion mean
# "the pane process was interrupted" rather than "something died".
trap 'touch /tmp/abx-standin-interrupted; exit 130' INT
while :; do sleep 300 & wait \$!; done
INNER
chmod +x /tmp/abx-standin.sh
tmux new-session -d -s "run-${STANDIN}" -- /tmp/abx-standin.sh
sleep 1
tmux has-session -t "=run-${STANDIN}" && echo STANDIN-UP
SH
cat "${TMP_ROOT}/standin.out"
if grep -q 'STANDIN-UP' "${TMP_ROOT}/standin.out"; then
    ok "the stand-in run session is up and trapping INT"
else
    bad "the stand-in run session did not start"
fi

STOP_OUT="${TMP_ROOT}/stop-run.out"
STOP_T0=$(date +%s)
run_bounded 90 "$STOP_OUT" "$AGENTBOX" stop-run "$CLEAN_REPO" "$STANDIN"
stop_rc=$BOUNDED_RC
STOP_ELAPSED=$(( $(date +%s) - STOP_T0 ))
cat "$STOP_OUT"
printf 'stop-run took %ss\n' "$STOP_ELAPSED"
if [ "$stop_rc" -eq 0 ]; then ok "stop-run exited 0"; else bad "stop-run exited ${stop_rc}"; fi

if guest test -e /tmp/abx-standin-interrupted; then
    ok "the stand-in actually received SIGINT"
else
    bad "the stand-in was never signalled; the stop was a status write, not a stop"
fi
if [ "$STOP_ELAPSED" -lt 20 ]; then
    ok "the stop completed in ${STOP_ELAPSED}s, before the 20s fallback"
else
    bad "the stop took ${STOP_ELAPSED}s; it fell through to killing the session"
fi

STOP_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$STANDIN" 2>/dev/null | tr -d '\r\n')
printf 'state after stop-run: %s\n' "$STOP_STATE"
if [ "$STOP_STATE" = "exit:stopped" ]; then
    ok "the run records exit:stopped"
else
    bad "the run records '${STOP_STATE}', not exit:stopped"
fi
if guest tmux has-session -t "=run-${STANDIN}" 2>/dev/null; then
    bad "the tmux session survived stop-run"
else
    ok "the tmux session was closed"
fi
if "$AGENTBOX" runs "$CLEAN_REPO" | grep -qE "${STANDIN}.*stopped"; then
    ok "runs shows the stopped run as stopped"
else
    bad "runs does not show the stopped run as stopped"
fi

printf -- '\n--- stopping a run that has already ended is refused, not overwritten ---\n'
AGAIN_OUT="${TMP_ROOT}/stop-again.out"
run_bounded 60 "$AGAIN_OUT" "$AGENTBOX" stop-run "$CLEAN_REPO" "$STANDIN"
again_rc=$BOUNDED_RC
cat "$AGAIN_OUT"
if [ "$again_rc" -ne 0 ] && grep -q 'already ended' "$AGAIN_OUT"; then
    ok "stop-run refused a run that had already ended"
else
    bad "stop-run did not refuse a run that had already ended"
fi

printf -- '\n--- a finished run keeps its own exit code ---\n'
FINISHED=20260101-111111
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${FINISHED}"
rm -rf "\$d"; mkdir -p "\$d"; chmod 700 "\$d"
printf 'exit:0\n' > "\$d/status"
printf '{"runid":"${FINISHED}","model":"sonnet","branch":null,"brief":"finished","started_at":"2026-01-01T11:11:11Z","tmux":null,"max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
SH
KEEP_OUT="${TMP_ROOT}/stop-finished.out"
run_bounded 60 "$KEEP_OUT" "$AGENTBOX" stop-run "$CLEAN_REPO" "$FINISHED"
cat "$KEEP_OUT"
KEEP_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$FINISHED" 2>/dev/null | tr -d '\r\n')
printf 'state of the finished run afterwards: %s\n' "$KEEP_STATE"
if [ "$KEEP_STATE" = "exit:0" ]; then
    ok "a finished run's exit code survived stop-run"
else
    bad "stop-run overwrote a finished run's exit code with '${KEEP_STATE}'"
fi

printf -- '\n--- with nothing running, stop-run says so instead of picking one ---\n'
NONE_OUT="${TMP_ROOT}/stop-none.out"
run_bounded 60 "$NONE_OUT" "$AGENTBOX" stop-run "$CLEAN_REPO"
none_rc=$BOUNDED_RC
cat "$NONE_OUT"
if [ "$none_rc" -ne 0 ] && grep -q 'no run is running' "$NONE_OUT"; then
    ok "stop-run with no argument refused when nothing was running"
else
    bad "stop-run with no argument did not refuse when nothing was running"
fi

printf -- '\n--- with no argument it picks the newest RUNNING run, not the newest ---\n'
OLD_RUNNING=20260101-222222
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${OLD_RUNNING}"
rm -rf "\$d"; mkdir -p "\$d"; chmod 700 "\$d"
printf 'running\n' > "\$d/status"
printf '{"runid":"${OLD_RUNNING}","model":"sonnet","branch":null,"brief":"old-running","started_at":"2026-01-01T22:22:22Z","tmux":"run-${OLD_RUNNING}","max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
rm -f /tmp/abx-old-interrupted
cat > /tmp/abx-old.sh <<'INNER'
#!/bin/bash
trap 'touch /tmp/abx-old-interrupted; exit 130' INT
while :; do sleep 300 & wait \$!; done
INNER
chmod +x /tmp/abx-old.sh
tmux new-session -d -s "run-${OLD_RUNNING}" -- /tmp/abx-old.sh
sleep 1
SH
# A finished run with a NEWER id than the running one, so that "newest" and
# "newest running" are genuinely different answers and the assertion below can
# tell which one stop-run used.
NEWEST_FINISHED=20260101-333333
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${NEWEST_FINISHED}"
rm -rf "\$d"; mkdir -p "\$d"; chmod 700 "\$d"
printf 'exit:0\n' > "\$d/status"
printf '{"runid":"${NEWEST_FINISHED}","model":"sonnet","branch":null,"brief":"newest-finished","started_at":"2026-01-01T33:33:33Z","tmux":null,"max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
SH
PICK_OUT="${TMP_ROOT}/stop-pick.out"
run_bounded 90 "$PICK_OUT" "$AGENTBOX" stop-run "$CLEAN_REPO"
cat "$PICK_OUT"
if grep -q "stopping ${OLD_RUNNING}" "$PICK_OUT"; then
    ok "stop-run chose the newest RUNNING run, not the newest run"
else
    bad "stop-run did not choose the newest running run"
fi
NEWEST_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$NEWEST_FINISHED" 2>/dev/null | tr -d '\r\n')
if [ "$NEWEST_STATE" = "exit:0" ]; then
    ok "the newer finished run was left alone"
else
    bad "the newer finished run was rewritten to '${NEWEST_STATE}'"
fi

printf -- '\n--- a run left saying running with nothing behind it becomes lost ---\n'
ORPHAN=20260101-444444
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${ORPHAN}"
rm -rf "\$d"; mkdir -p "\$d"; chmod 700 "\$d"
printf 'running\n' > "\$d/status"
printf '999999\n' > "\$d/pid"
printf '{"runid":"${ORPHAN}","model":"sonnet","branch":null,"brief":"orphan","started_at":"2026-01-01T44:44:44Z","tmux":"run-${ORPHAN}","max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
SH
ORPHAN_RUNS="${TMP_ROOT}/orphan-runs.out"
"$AGENTBOX" runs "$CLEAN_REPO" > "$ORPHAN_RUNS" 2>&1
cat "$ORPHAN_RUNS"
ORPHAN_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$ORPHAN" 2>/dev/null | tr -d '\r\n')
printf 'orphan state after runs: %s\n' "$ORPHAN_STATE"
if [ "$ORPHAN_STATE" = "exit:lost" ]; then
    ok "runs reconciled the orphaned run to exit:lost"
else
    bad "the orphaned run is still '${ORPHAN_STATE}'; it would say running for ever"
fi
if grep -qE "${ORPHAN}.*lost" "$ORPHAN_RUNS"; then
    ok "runs shows it in the lost state"
else
    bad "runs does not show the lost state"
fi

printf -- '\n--- procps is installed, which is what makes the signal find claude ---\n'
if guest sh -c 'command -v pgrep >/dev/null 2>&1'; then
    ok "pgrep is present in the guest"
else
    bad "pgrep is missing; stop-run cannot find the process tree"
fi

guest sh -c 'rm -f /tmp/abx-standin.sh /tmp/abx-old.sh /tmp/abx-standin-interrupted /tmp/abx-old-interrupted' || true
guest sh -c "rm -rf \$HOME/.agent-box/runs/${STANDIN} \$HOME/.agent-box/runs/${FINISHED} \$HOME/.agent-box/runs/${OLD_RUNNING} \$HOME/.agent-box/runs/${NEWEST_FINISHED} \$HOME/.agent-box/runs/${ORPHAN}" || true

# ===========================================================================
step "8g. tmux sessions are listed, and a detached one can be attached to"
# ===========================================================================

guest tmux new-session -d -s shell -- sleep 600
SESS_OUT="${TMP_ROOT}/sessions.out"
"$AGENTBOX" sessions "$CLEAN_REPO" > "$SESS_OUT" 2>&1
cat "$SESS_OUT"
if grep -qE '^shell ' "$SESS_OUT"; then
    ok "sessions lists the detached shell session"
else
    bad "sessions does not list the detached shell session"
fi

SESSJ="${TMP_ROOT}/sessions.json"
"$AGENTBOX" sessions "$CLEAN_REPO" --json > "$SESSJ" 2>&1
cat "$SESSJ"
if jq -e 'map(select(.name == "shell")) | length == 1' "$SESSJ" >/dev/null 2>&1; then
    ok "sessions --json lists it with a name"
else
    bad "sessions --json does not list it"
fi
if jq -e 'map(select(.name == "shell"))[0] | has("age_s")' "$SESSJ" >/dev/null 2>&1; then
    ok "sessions --json carries an age"
else
    bad "sessions --json carries no age"
fi

# attach needs a terminal, so it gets one: `script` allocates a pty on macOS.
# A detach-client from the other side is what has to make it return.
printf -- '\n--- attach -r returns when the session detaches it ---\n'
ATTACH_OUT="${TMP_ROOT}/attach.out"
( sleep 8; "$LIMACTL" shell --workdir /work "$INSTANCE" -- tmux detach-client -s shell >/dev/null 2>&1 ) &
DETACHER=$!
ATTACH_T0=$(date +%s)
run_bounded 60 "$ATTACH_OUT" script -q /dev/null "$AGENTBOX" attach "$CLEAN_REPO" shell -r
attach_rc=$BOUNDED_RC
ATTACH_ELAPSED=$(( $(date +%s) - ATTACH_T0 ))
wait "$DETACHER" 2>/dev/null
head -20 "$ATTACH_OUT"
printf 'attach returned after %ss with status %s\n' "$ATTACH_ELAPSED" "$attach_rc"
# The detacher waits 8 seconds before detaching, so a genuine pass cannot be
# quicker than that. Without the elapsed check this step would pass if attach
# failed instantly, or if the subcommand did not exist at all.
if [ "$attach_rc" -eq 0 ] && [ "$ATTACH_ELAPSED" -ge 8 ]; then
    ok "attach held the session for ${ATTACH_ELAPSED}s and returned 0 when it was detached"
else
    bad "attach exited ${attach_rc} after ${ATTACH_ELAPSED}s; expected 0 after at least 8s"
fi
guest tmux kill-session -t '=shell' 2>/dev/null || true

# ===========================================================================
step "8h. status: the JSON contract, and --watch leaving on Ctrl-C"
# ===========================================================================
#
# Scoped to this instance. `agentbox status` with no argument reaches into
# every agent-box VM on the machine, and a test must not run anything inside a
# VM it did not create.

STATUS_OUT="${TMP_ROOT}/status.out"
"$AGENTBOX" status "$CLEAN_REPO" > "$STATUS_OUT" 2>&1
cat "$STATUS_OUT"
if grep -q "$INSTANCE" "$STATUS_OUT" && grep -q 'fw=drop' "$STATUS_OUT"; then
    ok "status names the box and reports the firewall as drop"
else
    bad "status does not name the box with fw=drop"
fi

STATUSJ="${TMP_ROOT}/status.json"
"$AGENTBOX" status "$CLEAN_REPO" --json > "$STATUSJ" 2>&1
cat "$STATUSJ"
if jq -e . "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json parses"
else
    bad "status --json does not parse"
fi
if jq -e '.generated_at and (.boxes | length == 1)' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json has generated_at and exactly this box"
else
    bad "status --json is not shaped as documented"
fi
if jq -e '.boxes[0] | .firewall == "drop"' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json reports firewall drop"
else
    bad "status --json does not report firewall drop"
fi
if jq -e '.boxes[0] | has("name") and has("instance") and has("repo") and has("state") and has("claude_version") and has("run") and has("runs_total") and has("sessions")' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json carries every documented key"
else
    bad "status --json is missing documented keys"
fi
if jq -e '.boxes[0].run | has("id") and has("state") and has("elapsed_s") and has("turns") and has("cost_usd") and has("last_tool")' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json includes the current run object"
else
    bad "status --json has no run object"
fi
# The newest run stays in `run` after it has finished, with its state, its exit
# code and its total duration. Every run in this suite has ended by now, so a
# `run` of null here would mean the object disappears the moment it matters.
if jq -e '.boxes[0].run | .state == "failed" and .exit == 1 and (.elapsed_s | type) == "number"' "$STATUSJ" >/dev/null 2>&1; then
    ok "the newest run stays in status --json after it finished, with its exit code"
else
    bad "status --json does not keep a finished run with its state and exit code"
fi
if jq -e '.boxes[0].sessions | type == "array"' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json includes the session list"
else
    bad "status --json has no session list"
fi
if jq -e '.boxes[0].runs_total >= 1' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json counts the runs"
else
    bad "status --json does not count the runs"
fi

printf -- '\n--- status --watch 30 leaves within three seconds of SIGINT ---\n'
# THIRTY, not one. The spec's bound is three seconds whatever SECS is, and with
# --watch 1 the assertion cannot fail: a shell that simply waited out the
# interval would still be inside the bound. Thirty is far outside it, so this
# only passes if the interrupt is acted on rather than deferred.
WATCH_OUT="${TMP_ROOT}/watch.out"
# `set -m`, not decoration: without job control a non-interactive shell starts
# an asynchronous command with SIGINT ignored, and a signal the child cannot
# receive would make this step prove nothing.
set -m
"$AGENTBOX" status "$CLEAN_REPO" --watch 30 > "$WATCH_OUT" 2>&1 &
WATCH_PID=$!
set +m
sleep 6
kill -INT "$WATCH_PID" 2>/dev/null
WATCH_T0=$(date +%s)
WATCH_LEFT=0
for _attempt in 1 2 3 4 5 6; do
    kill -0 "$WATCH_PID" 2>/dev/null || { WATCH_LEFT=1; break; }
    sleep 0.5
done
wait "$WATCH_PID" 2>/dev/null
WATCH_ELAPSED=$(( $(date +%s) - WATCH_T0 ))
tail -5 "$WATCH_OUT"
printf 'watch exited after %ss (flag %s)\n' "$WATCH_ELAPSED" "$WATCH_LEFT"
if [ "$WATCH_LEFT" -eq 1 ] && [ "$WATCH_ELAPSED" -le 3 ]; then
    ok "status --watch exited within 3s of SIGINT"
else
    bad "status --watch took ${WATCH_ELAPSED}s to exit after SIGINT"
fi

# ===========================================================================
step "8i. hostile bytes from the guest are never executed or printed here"
# ===========================================================================
#
# The agent runs as the guest user with a Bash tool, so every file the host CLI
# reads out of the guest is a file the agent can write. Each check below plants
# the bytes an agent could plant and asserts the host neither runs them nor
# shows them.

PWN_MARKER="${TMP_ROOT}/PWNED"
rm -f "$PWN_MARKER"
HOSTILE_RUNID=20260102-000000
# Closes the AppleScript string literal and continues as AppleScript, where
# `do shell script` runs on the HOST, outside the VM. Also carries the array
# -subscript form that bash's arithmetic evaluator expands inside `[ -eq ]`.
HOSTILE_STATE="exit:0\" & (do shell script \"touch ${PWN_MARKER}\") & \"x[\$(touch ${PWN_MARKER})]"

guest bash -l > "${TMP_ROOT}/hostile-setup.out" 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${HOSTILE_RUNID}"
mkdir -p "\$d"; chmod 700 "\$d"
printf '%s' '${HOSTILE_STATE}' > "\$d/status"
printf '{"runid":"${HOSTILE_RUNID}","model":"sonnet","branch":null,"brief":"hostile","started_at":"2026-01-02T00:00:00Z","tmux":null,"max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
: > "\$d/events.jsonl"
: > "\$d/console.log"
wc -c < "\$d/status"
SH
cat "${TMP_ROOT}/hostile-setup.out"

printf -- '\n--- B-01/B-07: the host reads that state through three commands ---\n'
WATCH_RUN_OUT="${TMP_ROOT}/watch-run.out"
run_bounded 60 "$WATCH_RUN_OUT" "$AGENTBOX" watch-run "$INSTANCE" "$HOSTILE_RUNID" "$CLEAN_REPO"
cat "$WATCH_RUN_OUT"
HOSTILE_LOGS="${TMP_ROOT}/hostile-logs.out"
run_bounded 60 "$HOSTILE_LOGS" "$AGENTBOX" logs "$CLEAN_REPO" "$HOSTILE_RUNID"
cat "$HOSTILE_LOGS"
HOSTILE_STATUS="${TMP_ROOT}/hostile-status.json"
"$AGENTBOX" status "$CLEAN_REPO" --json > "$HOSTILE_STATUS" 2>&1
HOSTILE_RUNS="${TMP_ROOT}/hostile-runs.out"
"$AGENTBOX" runs "$CLEAN_REPO" > "$HOSTILE_RUNS" 2>&1

if [ -e "$PWN_MARKER" ]; then
    bad "SECURITY: guest-written bytes executed a command on the host"
    rm -f "$PWN_MARKER"
else
    ok "no guest-written byte executed anything on the host"
fi
if grep -q 'do shell script' "$WATCH_RUN_OUT" "$HOSTILE_LOGS" "$HOSTILE_STATUS" "$HOSTILE_RUNS" 2>/dev/null; then
    bad "the hostile state was echoed back to the host terminal"
else
    ok "the hostile state was never echoed to the host terminal"
fi
if grep -q 'not a run state' "$WATCH_RUN_OUT"; then
    ok "the host reported the unrecognised state instead of using it"
else
    bad "the host did not report the unrecognised state"
fi
if grep -q 'unknown' "$HOSTILE_RUNS"; then
    ok "runs shows the hostile run in an unknown state"
else
    bad "runs did not fall back to unknown for the hostile state"
fi

printf -- '\n--- B-08: a run id that is not a run id is refused on the host ---\n'
# shellcheck disable=SC2016  # these must stay literal; that is the point.
for bad_id in '../../.ssh' 'x[$(touch /tmp/nope)]' '2026-1-2'; do
    TRAV_OUT="${TMP_ROOT}/traversal.out"
    "$AGENTBOX" logs "$CLEAN_REPO" "$bad_id" > "$TRAV_OUT" 2>&1
    trav_rc=$?
    printf 'logs %-22s -> rc=%s %s\n' "$bad_id" "$trav_rc" "$(head -1 "$TRAV_OUT")"
    if [ "$trav_rc" -ne 0 ] && grep -q 'not a run id' "$TRAV_OUT"; then
        ok "logs refused the run id ${bad_id}"
    else
        bad "logs did not refuse the run id ${bad_id}"
    fi
    "$AGENTBOX" stop-run "$CLEAN_REPO" "$bad_id" > "$TRAV_OUT" 2>&1
    trav_rc=$?
    if [ "$trav_rc" -ne 0 ] && grep -q 'not a run id' "$TRAV_OUT"; then
        ok "stop-run refused the run id ${bad_id}"
    else
        bad "stop-run did not refuse the run id ${bad_id}"
    fi
done
# shellcheck disable=SC2016  # $HOME must expand in the guest.
if guest sh -c 'test -e "$HOME/.ssh/status"'; then
    bad "a status file was written outside the runs directory"
else
    ok "nothing was written outside the runs directory"
fi

printf -- '\n--- B-02: a tmux session named after the token is not printed ---\n'
guest tmux new-session -d -s "$FAKE_TOKEN" -- sleep 300 2>/dev/null || true
SESS_TOK="${TMP_ROOT}/sessions-token.out"
"$AGENTBOX" sessions "$CLEAN_REPO" > "$SESS_TOK" 2>&1
cat "$SESS_TOK"
SESS_TOKJ="${TMP_ROOT}/sessions-token.json"
"$AGENTBOX" sessions "$CLEAN_REPO" --json > "$SESS_TOKJ" 2>&1
cat "$SESS_TOKJ"
if grep -qF "$FAKE_TOKEN" "$SESS_TOK" "$SESS_TOKJ"; then
    bad "SECURITY: sessions printed the whole token"
else
    ok "sessions did not print the token"
fi
if grep -qF "$FAKE_HEAD" "$SESS_TOK" "$SESS_TOKJ" || grep -qF "$FAKE_TAIL" "$SESS_TOK" "$SESS_TOKJ"; then
    bad "sessions printed a fragment of the token"
else
    ok "sessions printed neither the token's head nor its tail"
fi
if grep -q 'redacted' "$SESS_TOK"; then
    ok "sessions redacted the credential-shaped session name"
else
    bad "sessions did not redact the credential-shaped session name"
fi
guest tmux kill-session -t "=${FAKE_TOKEN}" 2>/dev/null || true

printf -- '\n--- B-05: a session name full of JSON cannot forge or erase a row ---\n'
guest tmux new-session -d -s 'shell' -- sleep 300 2>/dev/null || true
JSON_NAME='x","age_s":0},{"name":"ghost'
guest tmux new-session -d -s "$JSON_NAME" -- sleep 300 2>/dev/null || true
FORGE="${TMP_ROOT}/sessions-forge.json"
"$AGENTBOX" sessions "$CLEAN_REPO" --json > "$FORGE" 2>&1
cat "$FORGE"
if jq -e . "$FORGE" >/dev/null 2>&1; then
    ok "sessions --json still parses with a hostile session name"
else
    bad "a hostile session name broke sessions --json"
fi
if jq -e 'map(select(.name == "ghost")) | length == 0' "$FORGE" >/dev/null 2>&1; then
    ok "no session row was forged"
else
    bad "a session row was forged by the name"
fi
FORGE_STATUS="${TMP_ROOT}/status-forge.json"
"$AGENTBOX" status "$CLEAN_REPO" --json > "$FORGE_STATUS" 2>&1
if jq -e '.boxes[0].sessions | type == "array" and length >= 2' "$FORGE_STATUS" >/dev/null 2>&1; then
    ok "status --json still lists the real sessions"
else
    bad "status --json lost the session list to a hostile name"
fi
guest tmux kill-session -t "=${JSON_NAME}" 2>/dev/null || true
guest tmux kill-session -t '=shell' 2>/dev/null || true

printf -- '\n--- B-03: a whole credential in a tool result is dropped, not trimmed ---\n'
LEAKY_RUNID=20260103-000000
OTHER_CRED="sk-ant-oat01-AAAAAAAAAABBBBBBBBBBCCCCCCCCCCDDDDDDDDDD"
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${LEAKY_RUNID}"
mkdir -p "\$d"; chmod 700 "\$d"
printf 'exit:3\n' > "\$d/status"
printf '{"runid":"${LEAKY_RUNID}","model":"sonnet","branch":null,"brief":"leaky","started_at":"2026-01-03T00:00:00Z","tmux":null,"max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
printf '%s\n' '{"type":"user","timestamp":"2026-01-03T00:00:01.000Z","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"CLAUDE_CODE_OAUTH_TOKEN=${OTHER_CRED}"}]}]}}' > "\$d/events.jsonl"
: > "\$d/console.log"
SH
LEAKY_OUT="${TMP_ROOT}/leaky-logs.out"
run_bounded 60 "$LEAKY_OUT" "$AGENTBOX" logs "$CLEAN_REPO" "$LEAKY_RUNID"
cat "$LEAKY_OUT"
if grep -qF "$OTHER_CRED" "$LEAKY_OUT"; then
    bad "SECURITY: logs printed a whole credential from a leak-flagged run"
else
    ok "logs printed no credential for the leak-flagged run"
fi
if grep -q 'leak check found the OAuth token' "$LEAKY_OUT"; then
    ok "logs printed the leak banner instead of the events"
else
    bad "logs did not print the leak banner"
fi
LEAKY_FORCED="${TMP_ROOT}/leaky-forced.out"
run_bounded 60 "$LEAKY_FORCED" "$AGENTBOX" logs "$CLEAN_REPO" "$LEAKY_RUNID" --force-unsafe
cat "$LEAKY_FORCED"
if grep -qF "$OTHER_CRED" "$LEAKY_FORCED"; then
    bad "SECURITY: --force-unsafe printed the credential verbatim"
else
    ok "even --force-unsafe drops the whole credential, not just its ends"
fi
if grep -q 'redacted' "$LEAKY_FORCED"; then
    ok "the credential was replaced by a redaction marker"
else
    bad "no redaction marker where the credential was"
fi

printf -- '\n--- B-09: the hook command refuses a destination outside the state root ---\n'
HOOKC_OUT="${TMP_ROOT}/hook-contain.out"
guest bash -l > "$HOOKC_OUT" 2>&1 <<'SH'
set -u
rm -rf /tmp/abx-outside && mkdir -p /tmp/abx-outside
printf '%s' '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/work/x"}}' \
    | AGENT_BOX_EVENTS_DIR=/tmp/abx-outside /opt/agent-box/guest/hook-event.sh
echo "RC_OUTSIDE=$?"
echo "FILES_OUTSIDE=$(find /tmp/abx-outside -type f | wc -l | tr -d ' ')"
d="$HOME/.agent-box/sessions/linktest"
rm -rf "$d" && mkdir -p "$d"
ln -s /tmp/abx-outside/stolen.jsonl "$d/hooks.jsonl"
printf '%s' '{"session_id":"s","hook_event_name":"Stop"}' \
    | AGENT_BOX_EVENTS_DIR="$d" /opt/agent-box/guest/hook-event.sh
echo "RC_SYMLINK=$?"
echo "SYMLINK_TARGET=$( [ -e /tmp/abx-outside/stolen.jsonl ] && echo WRITTEN || echo untouched )"
rm -rf /tmp/abx-outside "$d"
SH
cat "$HOOKC_OUT"
if grep -q 'RC_OUTSIDE=0' "$HOOKC_OUT" && grep -q 'FILES_OUTSIDE=0' "$HOOKC_OUT"; then
    ok "the hook wrote nothing outside the state root, and still exited 0"
else
    bad "the hook wrote outside the state root or failed"
fi
if grep -q 'SYMLINK_TARGET=untouched' "$HOOKC_OUT"; then
    ok "the hook refused a hooks.jsonl that is a symlink"
else
    bad "the hook followed a symlink out of the state root"
fi

printf -- '\n--- B-10: the state root itself is 700 ---\n'
# shellcheck disable=SC2016  # $HOME must expand in the guest.
STATE_MODE=$(guest sh -c 'stat -c "%a" "$HOME/.agent-box"' 2>/dev/null)
printf 'mode of ~/.agent-box: %s\n' "$STATE_MODE"
if [ "$STATE_MODE" = "700" ]; then
    ok "the state root is 700"
else
    bad "the state root is ${STATE_MODE}, expected 700"
fi
# And the case provisioning does not cover: a state root created by a script,
# under a permissive umask. abx_private_dir has to make the parent private too,
# or the layout the spec states is not what the code guarantees on its own.
MODE_OUT="${TMP_ROOT}/state-mode.out"
guest bash -l > "$MODE_OUT" 2>&1 <<'SH'
die() { printf 'lib refused: %s\n' "$*" >&2; exit 1; }
rm -rf /tmp/abx-modetest
export ABX_STATE_DIR=/tmp/abx-modetest
export ABX_RUNS_DIR=/tmp/abx-modetest/runs
# shellcheck source=/dev/null
. /opt/agent-box/guest/lib.sh
umask 022
abx_private_dir "$ABX_RUNS_DIR"
abx_private_dir "${ABX_RUNS_DIR}/20260101-000000"
stat -c '%a %n' /tmp/abx-modetest /tmp/abx-modetest/runs /tmp/abx-modetest/runs/20260101-000000
rm -rf /tmp/abx-modetest
SH
cat "$MODE_OUT"
if [ "$(grep -c '^700 ' "$MODE_OUT")" -eq 3 ]; then
    ok "a state root created by a script is 700 all the way down, under umask 022"
else
    bad "a script-created state root is not 700 all the way down"
fi

printf -- '\n--- B-12: --settings merges the hooks rather than replacing them ---\n'
MERGE_OUT="${TMP_ROOT}/settings-merge.out"
guest bash -l > "$MERGE_OUT" 2>&1 <<'SH'
set -u
w=/tmp/abx-merge; rm -rf "$w"; mkdir -p "$w/cfg" "$w/out" "$w/proj"
printf '#!/bin/sh\ncat >/dev/null\ntouch %s/out/user.marker\nexit 0\n' "$w" > "$w/hook-user.sh"
printf '#!/bin/sh\ncat >/dev/null\ntouch %s/out/extra.marker\nexit 0\n' "$w" > "$w/hook-extra.sh"
chmod +x "$w/hook-user.sh" "$w/hook-extra.sh"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/hook-user.sh"}]}]}}\n' "$w" > "$w/cfg/settings.json"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/hook-extra.sh"}]}]}}\n' "$w" > "$w/extra.json"
cd "$w/proj"
# `< /dev/null`, and it is load-bearing: this whole script arrives on bash's
# stdin, so a claude that inherits it eats the rest of the script and the two
# echoes below never run.
CLAUDE_CONFIG_DIR="$w/cfg" CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-MERGEHEADzzzzzzzzzzzzzzzzzzzzMERGETAIL' \
  timeout 120 claude -p --model haiku --settings "$w/extra.json" 'hi' >/dev/null 2>&1 </dev/null
echo "USER_HOOK=$( [ -f "$w/out/user.marker" ] && echo RAN || echo absent )"
echo "EXTRA_HOOK=$( [ -f "$w/out/extra.marker" ] && echo RAN || echo absent )"
rm -rf "$w"
SH
cat "$MERGE_OUT"
if grep -q 'USER_HOOK=RAN' "$MERGE_OUT" && grep -q 'EXTRA_HOOK=RAN' "$MERGE_OUT"; then
    ok "--settings MERGES hook arrays with the user settings.json"
else
    bad "--settings did not merge; the sensor's hooks can be displaced (see docs/decisions.md)"
fi

printf -- '\n--- B-12: a repository settings.json with hooks is refused ---\n'
REPOSET="${TMP_ROOT}/repo-settings.out"
guest sh -c 'mkdir -p /work/.claude && printf "%s\n" "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"touch /tmp/repo-hook-ran\"}]}]}}" > /work/.claude/settings.json'
printf 'Do nothing.\n' | "$LIMACTL" shell --workdir /work "$INSTANCE" -- \
    /opt/agent-box/guest/agent-run.sh --slug reposettings --brief - > "$REPOSET" 2>&1
reposet_rc=$?
cat "$REPOSET"
if [ "$reposet_rc" -ne 0 ] && grep -q 'hooks' "$REPOSET" && grep -q '/work/.claude/settings.json' "$REPOSET"; then
    ok "agent-run refused a repository settings.json carrying hooks, and named it"
else
    bad "agent-run did not refuse a repository settings.json carrying hooks"
fi
guest sh -c 'rm -rf /work/.claude /tmp/repo-hook-ran'

# Clean up everything this step planted in the guest.
guest sh -c "rm -rf \$HOME/.agent-box/runs/${HOSTILE_RUNID} \$HOME/.agent-box/runs/${LEAKY_RUNID}" || true

# ===========================================================================
step "8j. an interrupted run is recorded as stopped, not as done (issue #14)"
# ===========================================================================
#
# Claude Code exits 0 when it is interrupted and says so only in its result
# event, so a run that was stopped used to be recorded as `done` with exit 0.
# A stand-in CLI reproduces that shape exactly, without a model call and
# without the real credential path: it never reads a token and never prints
# one.
#
# The stand-in has to sit where the real one does. guest/lib.sh puts
# "$HOME/.local/bin" at the FRONT of PATH, so prepending a directory of our own
# would lose to the real binary; the real one is moved aside for the duration
# of this step and put back at the end, which is asserted.

guest bash -l > "${TMP_ROOT}/standin-install.out" 2>&1 <<'SH'
set -u
# (a) interrupted: prints an init line, then on SIGINT the shape issue #14 is
# about — error_during_execution, is_error true, exit status 0.
cat > /tmp/abx-claude-stop <<'INNER'
#!/bin/bash
case "${1:-}" in
    --version) printf '2.1.261-standin (Claude Code)\n'; exit 0 ;;
    --help)    printf -- '--include-hook-events --max-budget-usd --settings --verbose\n'; exit 0 ;;
esac
on_int() {
    printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":3,"duration_ms":900,"total_cost_usd":0}\n'
    exit 0
}
trap on_int INT
printf '{"type":"system","subtype":"init","model":"stand-in","claude_code_version":"stand-in"}\n'
sleep 120 &
wait $!
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"duration_ms":1000,"total_cost_usd":0}\n'
exit 0
INNER
# (b) failed without any signal: the CLI's own verdict says error, and it still
# exits 0.
cat > /tmp/abx-claude-fail <<'INNER'
#!/bin/bash
case "${1:-}" in
    --version) printf '2.1.261-standin (Claude Code)\n'; exit 0 ;;
    --help)    printf -- '--include-hook-events --max-budget-usd --settings --verbose\n'; exit 0 ;;
esac
printf '{"type":"system","subtype":"init","model":"stand-in","claude_code_version":"stand-in"}\n'
printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":2,"duration_ms":500,"total_cost_usd":0}\n'
exit 0
INNER
chmod +x /tmp/abx-claude-stop /tmp/abx-claude-fail
mv "$HOME/.local/bin/claude" "$HOME/.local/bin/claude.real"
cp /tmp/abx-claude-stop "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
claude --version
SH
cat "${TMP_ROOT}/standin-install.out"
if grep -q 'standin' "${TMP_ROOT}/standin-install.out"; then
    ok "the stand-in CLI is in place"
else
    bad "the stand-in CLI could not be installed; the rest of this step is meaningless"
fi

# A token, because agent-run refuses without one. It is never read by the
# stand-in and never printed by it.
guest sh -c "umask 077; printf '%s' '${FAKE_TOKEN}' > \$HOME/.config/agent-box/token; chmod 600 \$HOME/.config/agent-box/token"

printf -- '\n--- (a) a detached run, stopped while it is going ---\n'
STOPPED_OUT="${TMP_ROOT}/issue14-run.out"
run_bounded 90 "$STOPPED_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md"
cat "$STOPPED_OUT"
S14_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$STOPPED_OUT" | head -1)
printf 'runid: %s\n' "${S14_RUNID:-<none>}"
if [ -z "$S14_RUNID" ]; then
    bad "the run did not start; skipping the rest of 8j"
    S14_RUNID=""
fi

if [ -n "$S14_RUNID" ]; then
    # Wait until the stand-in is genuinely running, so the stop lands on it
    # rather than on the preconditions.
    S14_READY=0
    for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if guest sh -c "grep -q '\"subtype\":\"init\"' \$HOME/.agent-box/runs/${S14_RUNID}/events.jsonl 2>/dev/null"; then
            S14_READY=1; break
        fi
        sleep 2
    done
    if [ "$S14_READY" -eq 1 ]; then ok "the stand-in run reached the CLI"; else bad "the stand-in run never reached the CLI"; fi

    S14_STOP="${TMP_ROOT}/issue14-stop.out"
    S14_T0=$(date +%s)
    run_bounded 90 "$S14_STOP" "$AGENTBOX" stop-run "$CLEAN_REPO" "$S14_RUNID"
    S14_ELAPSED=$(( $(date +%s) - S14_T0 ))
    cat "$S14_STOP"
    printf 'stop-run took %ss\n' "$S14_ELAPSED"
    if grep -q "${S14_RUNID} stopped after" "$S14_STOP"; then
        ok "run-ctl reported the run as stopped"
    else
        bad "run-ctl did not report the run as stopped"
    fi
    # The two stop paths are worded differently. This one must be the path
    # where the RUN recorded its own exit, not the one where the session was
    # closed and the status written from outside.
    if grep -q 'did not record its own exit' "$S14_STOP"; then
        bad "the run did not record its own stop; the status was written from outside"
    else
        ok "the run recorded its own stop; run-ctl only reported it"
    fi
    if [ "$S14_ELAPSED" -lt 20 ]; then
        ok "the stop completed in ${S14_ELAPSED}s, without falling through to the 20s fallback"
    else
        bad "the stop took ${S14_ELAPSED}s; it fell through to closing the session"
    fi
    if grep -q 'ended by itself' "$S14_STOP"; then
        bad "run-ctl still claims the run ended by itself"
    else
        ok "run-ctl no longer claims the run ended by itself"
    fi

    S14_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$S14_RUNID" 2>/dev/null | tr -d '\r\n')
    printf 'status file: %s\n' "$S14_STATE"
    if [ "$S14_STATE" = "exit:stopped" ]; then
        ok "the run recorded exit:stopped"
    else
        bad "the run recorded '${S14_STATE}', not exit:stopped"
    fi

    S14_JSON="${TMP_ROOT}/issue14-runs.json"
    "$AGENTBOX" runs "$CLEAN_REPO" --json > "$S14_JSON" 2>&1
    cat "$S14_JSON"
    if jq -e --arg r "$S14_RUNID" 'map(select(.runid == $r and .state == "stopped" and .exit_code == null)) | length == 1' "$S14_JSON" >/dev/null 2>&1; then
        ok "runs --json reports it stopped with a null exit code"
    else
        bad "runs --json does not report it stopped with a null exit code"
    fi

    S14_BRANCH=$(guest sh -c "jq -r '.branch // empty' \$HOME/.agent-box/runs/${S14_RUNID}/meta.json" 2>/dev/null | tr -d '\r\n')
    printf 'branch: %s\n' "${S14_BRANCH:-<none>}"
    if [ -n "$S14_BRANCH" ] && guest sh -c "git -C /work rev-parse --verify --quiet '${S14_BRANCH}' >/dev/null"; then
        ok "the run's branch still exists; nothing was reverted"
    else
        bad "the run's branch is gone after a stop"
    fi

    # The summary the run wrote, read back through the guest so it is scrubbed.
    # It must be THIS run's summary and it must say stopped: a run that was
    # killed before it could write one would otherwise leave the previous
    # run's summary in place and look fine.
    S14_SUMMARY="${TMP_ROOT}/issue14-summary.out"
    run_bounded 60 "$S14_SUMMARY" guest_summary "$S14_RUNID"
    cat "$S14_SUMMARY"
    if grep -q "runid     : ${S14_RUNID}" "$S14_SUMMARY" && grep -q 'state     : stopped' "$S14_SUMMARY"; then
        ok "the run wrote its own summary, naming the state as stopped"
    else
        bad "the run did not write a summary saying stopped"
    fi
    if grep -q 'Nothing was reverted' "$S14_SUMMARY"; then
        ok "the summary says nothing was reverted"
    else
        bad "the summary does not say nothing was reverted"
    fi
fi

printf -- '\n--- (a2) run --wait on a run that gets stopped returns 130 ---\n'
WAIT_OUT="${TMP_ROOT}/issue14-wait.out"
set -m
"$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md" --wait > "$WAIT_OUT" 2>&1 &
WAIT_PID=$!
set +m
W14_READY=0
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if guest /opt/agent-box/guest/run-ctl.sh state 2>/dev/null | grep -qx 'running'; then
        W14_READY=1; break
    fi
    sleep 2
done
sleep 3
run_bounded 90 "${TMP_ROOT}/issue14-wait-stop.out" "$AGENTBOX" stop-run "$CLEAN_REPO"
cat "${TMP_ROOT}/issue14-wait-stop.out"
wait "$WAIT_PID"; wait_rc=$?
cat "$WAIT_OUT"
printf 'run --wait exit status: %s (ready flag %s)\n' "$wait_rc" "$W14_READY"
if [ "$wait_rc" -eq 130 ]; then
    ok "run --wait returned 130 for a run that was stopped"
else
    bad "run --wait returned ${wait_rc}; expected 130 for a stopped run"
fi
if grep -q 'summary' "$WAIT_OUT"; then
    ok "run --wait printed the summary for the stopped run"
else
    bad "run --wait printed no summary for the stopped run"
fi

printf -- '\n--- (b) the CLI exits 0 but says is_error: that is a failed run ---\n'
# shellcheck disable=SC2016  # $HOME must expand in the guest.
guest bash -l -c 'cp /tmp/abx-claude-fail "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"'
FAIL_OUT="${TMP_ROOT}/issue14-fail.out"
run_bounded 120 "$FAIL_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md" --wait
fail_rc=$BOUNDED_RC
cat "$FAIL_OUT"
printf 'run --wait exit status: %s\n' "$fail_rc"
F14_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$FAIL_OUT" | head -1)
F14_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$F14_RUNID" 2>/dev/null | tr -d '\r\n')
printf 'status file: %s\n' "$F14_STATE"
if [ "$F14_STATE" = "exit:1" ]; then
    ok "a CLI that exits 0 while reporting is_error is recorded as exit:1"
else
    bad "the run recorded '${F14_STATE}', not exit:1"
fi
if "$AGENTBOX" runs "$CLEAN_REPO" | grep -qE "${F14_RUNID}.*failed"; then
    ok "runs shows it as failed"
else
    bad "runs does not show it as failed"
fi
if [ "$fail_rc" -ne 0 ]; then
    ok "run --wait returned non-zero for the failed run"
else
    bad "run --wait returned 0 for a run the CLI said had failed"
fi
if grep -q 'is_error=true; recording this run as failed' "$FAIL_OUT"; then
    ok "agent-run said why it overrode the exit status"
else
    bad "agent-run did not explain the override"
fi

printf -- '\n--- no token fragment left this step ---\n'
if grep -qF "$FAKE_HEAD" "$STOPPED_OUT" "$S14_STOP" "$WAIT_OUT" "$FAIL_OUT" 2>/dev/null \
   || grep -qF "$FAKE_TAIL" "$STOPPED_OUT" "$S14_STOP" "$WAIT_OUT" "$FAIL_OUT" 2>/dev/null; then
    bad "a token fragment reached the host in step 8j"
else
    ok "no token fragment reached the host in step 8j"
fi

printf -- '\n--- the real CLI is put back ---\n'
# shellcheck disable=SC2016  # $HOME must expand in the guest.
guest bash -l -c 'mv -f "$HOME/.local/bin/claude.real" "$HOME/.local/bin/claude"' || true
guest sh -c 'rm -f /tmp/abx-claude-stop /tmp/abx-claude-fail'
REAL_VER=$("$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -lc 'claude --version' 2>&1)
printf '%s\n' "$REAL_VER"
if printf '%s' "$REAL_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' && ! printf '%s' "$REAL_VER" | grep -q standin; then
    ok "the real Claude Code is back on PATH"
else
    bad "the real Claude Code was not restored"
fi
# shellcheck disable=SC2016  # $HOME must expand in the guest.
guest sh -c 'rm -f $HOME/.config/agent-box/token'
guest sh -c 'cd /work && git checkout -- . 2>/dev/null; true'

printf -- '\n--- clean up the planted token and the run state ---\n'
# shellcheck disable=SC2016  # $HOME must expand in the guest, not on the host.
guest sh -c 'rm -f $HOME/.config/agent-box/token'
guest sh -c 'cd /work && git checkout -- . 2>/dev/null; git checkout --quiet main 2>/dev/null; true'
# shellcheck disable=SC2016  # $HOME must expand in the guest, not on the host.
guest sh -c 'rm -rf /work/.agent-box $HOME/.agent-box/runs $HOME/.agent-box/briefs' || true
if grep -rqF "$FAKE_TOKEN" "$CLEAN_REPO" 2>/dev/null; then
    bad "the planted token is still in the work tree after the sensor checks"
else
    ok "the work tree is clean of the planted token after the sensor checks"
fi

# ===========================================================================
step "8c. a first-run failure fails CLOSED without locking the operator out"
# ===========================================================================
#
# This is the FW-1 case: an error when there is no standing ruleset to fall back
# on. The rules are cleared to simulate a first boot, the GitHub meta endpoint is
# pointed at a closed port so the fetch fails, and the OUTPUT policy must be DROP
# afterwards rather than ACCEPT.
#
# The simulation runs as a detached transient unit so that it survives whatever
# happens to the network. It deliberately does NOT recover: the whole point of
# this step is to observe the hard-closed state from the host and to run the
# documented recovery over a real `limactl shell`, which is only possible if the
# hard close keeps SSH working.

FIRSTRUN_LOG=/tmp/agent-box-firstrun.log
guest sudo systemd-run --unit=agent-box-firstrun-test --collect /bin/sh -c "
exec > ${FIRSTRUN_LOG} 2>&1
echo '--- simulating a first-run state: no rules, no ipset ---'
iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
iptables -F; iptables -X 2>/dev/null
ipset destroy allowed-domains 2>/dev/null
echo \"BEFORE_POLICY=\$(iptables -S | grep -- '-P OUTPUT')\"
echo '--- running init-firewall.sh with an unreachable meta endpoint ---'
AGENT_BOX_GH_META_URL=http://127.0.0.1:9/meta /opt/agent-box/guest/init-firewall.sh
echo \"INIT_RC=\$?\"
if iptables -S | grep -qx -- '-P OUTPUT DROP'; then echo 'RESULT=POLICY-DROP'; else echo 'RESULT=POLICY-OPEN'; fi
iptables -S
echo 'SIMULATION_COMPLETE=1'
"

# The hard close is now in force and nothing has recovered it.
printf -- '--- can the operator still reach the guest while it is hard-closed? ---\n'
SHELL_OK=0
SHELL_PROBE="${TMP_ROOT}/shell-probe.out"
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    if run_bounded 20 "$SHELL_PROBE" "$LIMACTL" shell --workdir /work "$INSTANCE" -- \
        sh -c 'grep -q SIMULATION_COMPLETE /tmp/agent-box-firstrun.log && echo SHELL-ALIVE'
    then
        if grep -q 'SHELL-ALIVE' "$SHELL_PROBE"; then SHELL_OK=1; break; fi
    fi
    sleep 3
done
cat "$SHELL_PROBE"
if [ "$SHELL_OK" -eq 1 ]; then
    ok "limactl shell still answers while the hard close is in force"
else
    bad "limactl shell does not answer while the hard close is in force"
fi

printf -- '\n--- the transient unit log ---\n'
FR_OUT="${TMP_ROOT}/firstrun.out"
guest sudo cat "$FIRSTRUN_LOG" > "$FR_OUT" 2>&1
cat "$FR_OUT"

if grep -q '^RESULT=POLICY-DROP' "$FR_OUT"; then
    ok "a first-run failure left the OUTPUT policy at DROP"
else
    bad "a first-run failure did not leave the OUTPUT policy at DROP"
fi
if grep -q 'INIT_RC=0' "$FR_OUT"; then
    bad "init-firewall.sh reported success despite an unreachable meta endpoint"
else
    ok "init-firewall.sh failed as expected on the unreachable meta endpoint"
fi
if grep -q 'there is no standing ruleset' "$FR_OUT"; then
    ok "the hard-close branch was the one taken"
else
    bad "the hard-close branch was not taken"
fi
if grep -qE '^-A INPUT .*--dport 22 -j ACCEPT' "$FR_OUT"; then
    ok "the hard-close ruleset keeps inbound port 22"
else
    bad "the hard-close ruleset does not keep inbound port 22"
fi

# Shell access must not have come at the cost of the thing being tested.
printf -- '\n--- egress is genuinely closed in that state ---\n'
EG_OUT="${TMP_ROOT}/hardclose-egress.out"
if run_bounded 30 "$EG_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- \
    sh -c 'curl -sS -m 8 -o /dev/null https://github.com'
then
    bad "github.com was still reachable during the hard close"
else
    ok "github.com was unreachable during the hard close"
fi
cat "$EG_OUT"

# The documented recovery, run over the shell the hard close left open — which
# is the claim the printed message makes.
printf -- '\n--- running the documented recovery over that shell ---\n'
if guest sudo sh -c 'iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F'; then
    ok "the first documented recovery step ran over limactl shell"
else
    bad "the first documented recovery step could not be run over limactl shell"
fi
if guest sudo systemctl restart agent-box-firewall.service; then
    ok "the second documented recovery step restarted the firewall"
else
    bad "the second documented recovery step failed"
fi

FW_OUT3="${TMP_ROOT}/firewall3.out"
"$AGENTBOX" firewall-check "$CLEAN_REPO" > "$FW_OUT3" 2>&1
rc=$?
cat "$FW_OUT3"
if [ "$rc" -eq 0 ]; then ok "firewall-check passes again after the recovery"; else bad "firewall-check fails after the recovery"; fi

# ===========================================================================
step "9. provisioning is idempotent across a stop/start with the firewall up"
# ===========================================================================
#
# From the second boot onward the firewall service starts at multi-user.target
# and archive.ubuntu.com is not on the allowlist, so a provisioner that ran apt
# unconditionally would fail and take the whole start down with it.

printf -- '--- limactl stop ---\n'
if "$AGENTBOX" stop "$CLEAN_REPO"; then
    ok "agentbox stop exited 0"
else
    bad "agentbox stop did not exit 0"
fi

printf -- '\n--- limactl start (re-runs provisioning under the firewall) ---\n'
RESTART_TS=$(date +%s)
"$AGENTBOX" start "$CLEAN_REPO"
rc=$?
printf 'restart took %s seconds\n' "$(( $(date +%s) - RESTART_TS ))"
if [ "$rc" -eq 0 ]; then ok "agentbox start exited 0 after a stop"; else bad "agentbox start exited ${rc} after a stop"; fi

printf -- '\n--- the firewall is active again after the restart ---\n'
FW_STATE2=$(guest systemctl is-active agent-box-firewall 2>/dev/null)
printf '%s\n' "$FW_STATE2"
if [ "$FW_STATE2" = "active" ]; then ok "agent-box-firewall is active after restart"; else bad "agent-box-firewall is ${FW_STATE2} after restart"; fi

printf -- '\n--- claude survived the restart ---\n'
VER2=$("$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -lc 'claude --version' 2>&1)
printf '%s\n' "$VER2"
if printf '%s' "$VER2" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
    ok "claude is still installed after the restart"
else
    bad "claude is missing after the restart"
fi

printf -- '\n--- a firewall rebuild under the standing deny succeeds ---\n'
# This is the case the old script could not survive: rebuilding while the deny
# ruleset is already in force.
REBUILD="${TMP_ROOT}/rebuild.out"
guest sudo systemctl restart agent-box-firewall.service > "$REBUILD" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok "the firewall rebuilt while the deny was in force"; else bad "the firewall rebuild failed under the standing deny (exit ${rc})"; cat "$REBUILD"; fi

FW_OUT2="${TMP_ROOT}/firewall2.out"
"$AGENTBOX" firewall-check "$CLEAN_REPO" > "$FW_OUT2" 2>&1
rc=$?
cat "$FW_OUT2"
if [ "$rc" -eq 0 ]; then ok "firewall-check still passes after the rebuild"; else bad "firewall-check failed after the rebuild"; fi

# ===========================================================================
step "10. destroy the instance, by bare name"
# ===========================================================================
#
# By name rather than by path, which is what makes a VM removable after its
# repository directory is gone.

"$AGENTBOX" destroy "$INSTANCE"
rc=$?
if [ "$rc" -eq 0 ]; then ok "agentbox destroy exited 0 for a bare instance name"; else bad "agentbox destroy exited ${rc}"; fi

printf -- '\n--- limactl list ---\n'
"$LIMACTL" list 2>&1
if "$LIMACTL" list --quiet 2>/dev/null | grep -qxF "$INSTANCE"; then
    bad "${INSTANCE} is still listed after destroy"
else
    ok "${INSTANCE} is gone from limactl list"
fi

# ===========================================================================
hr
printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
hr
[ "$FAIL" -eq 0 ]
