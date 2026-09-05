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

# The second instance: the same box with the Docker and browser-testing
# profile. A separate VM rather than a flag on the first, because the profile
# is fixed at create time and the point is to prove both shapes work.
DOCKER_REPO="${TMP_ROOT}/dk-${SMOKE_ID}"
DOCKER_INSTANCE="agent-box-dk-${SMOKE_ID}"
FORWARD_PORT=3999

PASS=0
FAIL=0

hr()   { printf '%s\n' '==============================================================='; }
step() { hr; printf '## %s\n' "$*"; hr; }
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }

cleanup() {
    local rc=$? inst
    step "cleanup"
    for inst in "$INSTANCE" "$DOCKER_INSTANCE"; do
        if "$LIMACTL" list --quiet 2>/dev/null | grep -qxF "$inst"; then
            printf 'destroying %s\n' "$inst"
            "$AGENTBOX" destroy "$inst" || "$LIMACTL" delete --force "$inst" || true
        fi
    done
    rm -rf "$TMP_ROOT"
    printf 'Lima image cache under ~/Library/Caches/lima/download is left in place on purpose.\n'
    exit "$rc"
}
trap cleanup EXIT

# An explicit --workdir stops limactl from trying to cd into the host's
# working directory inside the guest, which warns on stderr every time.
guest()  { "$LIMACTL" shell --workdir /work "$INSTANCE" -- "$@"; }
dguest() { "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- "$@"; }

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
# The plugin this test installs from that marketplace. It is a real public
# marketplace, so this name tracks whatever it actually publishes: it was
# `governor` until 2026-09-05, when konyklabs/claude-plugins renamed it to
# `supervisor` on main and every install here began failing with
# `Plugin "governor" not found in marketplace "konyklabs-plugins"`.
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
# The installed check asserts the full identity, `<plugin>@konyklabs-plugins`,
# against the installed listing alone. A bare plugin name would also match the
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

RUN_OUT="${TMP_ROOT}/run.out"
printf 'Do nothing.\n' > "${TMP_ROOT}/noop-brief.md"
"$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md" > "$RUN_OUT" 2>&1
rc=$?
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
run_bounded 240 "$LEAK_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md"
leak_rc=$BOUNDED_RC
cat "$LEAK_OUT"
printf 'agentbox run exit status: %s\n' "$leak_rc"

if [ "$leak_rc" -eq 3 ]; then
    ok "agent-run exited 3 when the token appeared in output reaching the host"
else
    bad "agent-run exited ${leak_rc}; expected 3 for a token leak"
fi
if grep -q 'SECURITY: the token appears in' "$LEAK_OUT"; then
    ok "the leak was reported, naming the stream"
else
    bad "the leak was not reported"
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
# In AGENTBOX-IN, which INPUT rule 1 jumps to. The accept rules moved out of
# the builtin chains when the firewall started owning chains rather than the
# whole table, so both halves are asserted: the rule, and the jump that reaches
# it. A rule in an unreachable chain would let the operator out just as surely.
if grep -qE '^-A AGENTBOX-IN .*--dport 22 -j ACCEPT' "$FR_OUT" \
    && grep -qx -- '-A INPUT -j AGENTBOX-IN' "$FR_OUT"; then
    ok "the hard-close ruleset keeps inbound port 22, in a chain INPUT reaches"
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
step "11. a second instance with the Docker and browser-testing profile"
# ===========================================================================
#
# Everything from here down is about the opt-in profile: Docker Engine inside
# the guest, containers held to the same egress allowlist, a forwarded port,
# Node 22 with Playwright's system libraries, and Rosetta for amd64 images.
#
# A separate VM, not a flag on the first one. The profile is fixed at create
# time — that is the whole design — so the only way to test both shapes is to
# build both.

mkdir -p "$DOCKER_REPO"
git init -q "$DOCKER_REPO"
cat > "${DOCKER_REPO}/hello.txt" <<'EOF'
A second throwaway repository, for the Docker and Playwright profile.
EOF

printf 'This installs Docker Engine, Node 22 and Playwright system libraries.\n'
printf 'It is slower than the first create; it is not stuck.\n'
DK_CREATE_OUT="${TMP_ROOT}/dk-create.out"
DK_TS=$(date +%s)
run_bounded 2400 "$DK_CREATE_OUT" "$AGENTBOX" create "$DOCKER_REPO" \
    --docker --playwright --rosetta --forward "$FORWARD_PORT"
dk_rc=$BOUNDED_RC
cat "$DK_CREATE_OUT"
printf 'docker-profile create took %s seconds\n' "$(( $(date +%s) - DK_TS ))"
if [ "$dk_rc" -eq 0 ]; then ok "agentbox create --docker --playwright --rosetta succeeded"; else bad "that create exited ${dk_rc}"; fi

if grep -q 'WARNING: --forward' "$DK_CREATE_OUT"; then
    ok "--forward printed the widening warning"
else
    bad "--forward printed no warning"
fi
if grep -qE "^  forwarded +${FORWARD_PORT}\$" "$DK_CREATE_OUT"; then
    ok "the summary records the forwarded port"
else
    bad "the summary does not record the forwarded port"
fi
if grep -qE '^agentbox: sizing: 4 cpus, 8GiB memory, 60GiB disk$' "$DK_CREATE_OUT"; then
    ok "--docker raised the default sizing to 4/8GiB/60GiB"
else
    bad "--docker did not print the raised default sizing"
fi

if "$LIMACTL" list --quiet | grep -qxF "$DOCKER_INSTANCE"; then
    ok "instance ${DOCKER_INSTANCE} exists"
else
    bad "instance ${DOCKER_INSTANCE} does not exist; the remaining Docker checks cannot run"
    hr; printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"; hr
    exit 1
fi

printf -- '\n--- the sizing Lima actually gave it ---\n'
"$LIMACTL" list "$DOCKER_INSTANCE"

# ===========================================================================
step "12. Docker inside the guest, under the same allowlist"
# ===========================================================================

printf -- '--- docker info, as the NON-ROOT guest user ---\n'
# Not under sudo. A box where only root can talk to the daemon is a box the
# agent cannot use, and the agent is never root.
DI_OUT="${TMP_ROOT}/docker-info.out"
run_bounded 120 "$DI_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- \
    docker info --format '{{.ServerVersion}} {{.SecurityOptions}}'
cat "$DI_OUT"
if [ "$BOUNDED_RC" -eq 0 ] && grep -qE '^[0-9]+\.[0-9]+' "$DI_OUT"; then
    ok "docker info works as the non-root guest user"
else
    bad "docker info failed as the non-root guest user"
fi
# The rootless engine reports name=rootless among its security options and
# populates none of the DOCKER* chains, so this is the check that the profile
# installed the engine the allowlist can actually hook into.
if grep -q 'name=rootless' "$DI_OUT"; then
    bad "the daemon is rootless; DOCKER-USER would not exist"
else
    ok "the daemon is rootful, which is what populates DOCKER-USER"
fi

printf -- '\n--- docker pull alpine:3 through the allowlist ---\n'
PULL_OUT="${TMP_ROOT}/docker-pull.out"
run_bounded 300 "$PULL_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- \
    docker pull alpine:3
pull_rc=$BOUNDED_RC
tail -5 "$PULL_OUT"
if [ "$pull_rc" -eq 0 ]; then
    ok "docker pull alpine:3 succeeded, so the registry names are on the allowlist"
else
    bad "docker pull alpine:3 exited ${pull_rc}"
fi

printf -- '\n--- DOCKER-USER rule 1 ---\n'
DU_OUT="${TMP_ROOT}/docker-user.out"
dguest sudo iptables -S DOCKER-USER > "$DU_OUT" 2>&1
cat "$DU_OUT"
if [ "$(sed -n '2p' "$DU_OUT")" = "-A DOCKER-USER -j AGENTBOX-FWD" ]; then
    ok "DOCKER-USER rule 1 jumps to AGENTBOX-FWD"
else
    bad "DOCKER-USER rule 1 is not the AGENTBOX-FWD jump"
fi

printf -- '\n--- Docker chains are intact and ours sit beside them ---\n'
dguest sudo iptables -S 2>/dev/null | grep -E '^-N|^-P|^-A (FORWARD|DOCKER-USER)'

printf -- '\n--- container egress obeys the allowlist ---\n'
CEG_OUT="${TMP_ROOT}/container-egress.out"
dguest bash -c '
docker run --rm alpine:3 wget -T 5 -q -O /dev/null https://example.com 2>&1
echo "EXAMPLE_RC=$?"
docker run --rm alpine:3 wget -T 5 -q -O /dev/null https://api.anthropic.com/ 2>&1
echo "ANTHROPIC_RC=$?"
' > "$CEG_OUT" 2>&1
cat "$CEG_OUT"
if grep -q '^EXAMPLE_RC=0' "$CEG_OUT"; then
    bad "a container reached https://example.com"
else
    ok "a container could not reach https://example.com"
fi
# busybox wget exits 1 on an HTTP error too, so "connected" means either a zero
# exit or an answer from the server. A refused connection says so explicitly.
if grep -q '^ANTHROPIC_RC=0' "$CEG_OUT" || grep -q 'server returned error' "$CEG_OUT"; then
    ok "a container reached https://api.anthropic.com/"
else
    bad "a container could not reach https://api.anthropic.com/"
fi

printf -- '\n--- two containers on a user-defined network reach each other ---\n'
C2C_OUT="${TMP_ROOT}/c2c.out"
run_bounded 300 "$C2C_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
set -e
docker network create abxnet >/dev/null 2>&1 || true
docker rm -f abxsrv >/dev/null 2>&1 || true
docker run -d --name abxsrv --network abxnet alpine:3 \
    sh -c "while true; do printf \"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHELLO\" | nc -l -p 8000; done" >/dev/null
sleep 3
docker run --rm --network abxnet alpine:3 wget -T 5 -q -O - http://abxsrv:8000/
echo ""
echo "C2C_RC=$?"
docker rm -f abxsrv >/dev/null 2>&1 || true
'
cat "$C2C_OUT"
if grep -q 'HELLO' "$C2C_OUT" && grep -q '^C2C_RC=0' "$C2C_OUT"; then
    ok "two containers on a user-defined network reached each other"
else
    bad "container-to-container traffic on a user-defined network did not work"
fi

printf -- '\n--- a compose stack, published on the forwarded port ---\n'
STACK_OUT="${TMP_ROOT}/stack.out"
run_bounded 600 "$STACK_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c "
set -e
rm -rf /tmp/abx-stack && mkdir -p /tmp/abx-stack
cat > /tmp/abx-stack/compose.yaml <<'YML'
services:
  web:
    image: python:3-alpine
    command: python -m http.server 8000
    ports:
      - \"127.0.0.1:${FORWARD_PORT}:8000\"
YML
cd /tmp/abx-stack
docker compose up -d
for i in \$(seq 1 30); do
    code=\$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:${FORWARD_PORT}/ 2>/dev/null || true)
    [ \"\$code\" = 200 ] && break
    sleep 2
done
echo \"GUEST_HTTP=\$code\"
"
cat "$STACK_OUT"
if grep -q '^GUEST_HTTP=200' "$STACK_OUT"; then
    ok "the compose stack answers at 127.0.0.1:${FORWARD_PORT} inside the guest"
else
    bad "the compose stack does not answer inside the guest"
fi

printf -- '\n--- and on the host, through the forwarded port ---\n'
HOST_HTTP=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
    HOST_HTTP=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${FORWARD_PORT}/" 2>/dev/null || true)
    [ "$HOST_HTTP" = "200" ] && break
    sleep 2
done
printf 'host curl http://127.0.0.1:%s/ -> %s\n' "$FORWARD_PORT" "${HOST_HTTP:-<no answer>}"
if [ "$HOST_HTTP" = "200" ]; then
    ok "the forwarded port answers on the host at 127.0.0.1:${FORWARD_PORT}"
else
    bad "the forwarded port does not answer on the host"
fi

printf -- '\n--- a daemon restart leaves no unfiltered window ---\n'
# ExecStartPost, not the 15-minute timer. `systemctl restart docker` returning
# means the hook has already run, so the jump must be back immediately — not
# eventually.
RESTART_OUT="${TMP_ROOT}/docker-restart.out"
run_bounded 300 "$RESTART_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
sudo iptables -D DOCKER-USER -j AGENTBOX-FWD 2>/dev/null || true
echo "--- jump deliberately removed ---"
sudo iptables -S DOCKER-USER
sudo systemctl restart docker
echo "RESTART_RC=$?"
echo "--- immediately after the restart returned ---"
sudo iptables -S DOCKER-USER
docker run --rm alpine:3 echo CONTAINER_STILL_RUNS
'
cat "$RESTART_OUT"
if grep -q '^RESTART_RC=0' "$RESTART_OUT"; then
    ok "systemctl restart docker exited 0"
else
    bad "systemctl restart docker did not exit 0"
fi
if [ "$(grep -c -- '-A DOCKER-USER -j AGENTBOX-FWD' "$RESTART_OUT")" -ge 1 ]; then
    ok "the AGENTBOX-FWD jump was back in DOCKER-USER as soon as the restart returned"
else
    bad "the AGENTBOX-FWD jump was not restored by the restart"
fi
if grep -q 'CONTAINER_STILL_RUNS' "$RESTART_OUT"; then
    ok "a container still runs after the daemon restart"
else
    bad "no container could run after the daemon restart"
fi

printf -- '\n--- a forced firewall rebuild leaves Docker chains intact ---\n'
# `restart`, not `start`: agent-box-firewall is a RemainAfterExit oneshot, so
# `start` on an already-active unit does nothing at all and would make this
# check vacuous. This is the case the old whole-table `iptables-restore` broke:
# it replaced the filter table every fifteen minutes and took Docker's chains
# with it.
REBUILD_OUT="${TMP_ROOT}/dk-rebuild.out"
run_bounded 300 "$REBUILD_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
sudo systemctl restart agent-box-firewall.service
echo "FW_RC=$?"
echo "--- DOCKER-FORWARD ---"
sudo iptables -S DOCKER-FORWARD
echo "--- DOCKER-USER ---"
sudo iptables -S DOCKER-USER
docker run --rm alpine:3 echo CONTAINER_AFTER_REBUILD
'
cat "$REBUILD_OUT"
if grep -q '^FW_RC=0' "$REBUILD_OUT"; then
    ok "the firewall rebuilt on an instance running Docker"
else
    bad "the firewall rebuild failed on an instance running Docker"
fi
if [ "$(sed -n '/--- DOCKER-FORWARD ---/,/--- DOCKER-USER ---/p' "$REBUILD_OUT" | grep -c '^-A DOCKER-FORWARD')" -gt 0 ]; then
    ok "DOCKER-FORWARD still holds Docker's own rules after the rebuild"
else
    bad "DOCKER-FORWARD was emptied by the rebuild"
fi
if grep -q -- '-A DOCKER-USER -j AGENTBOX-FWD' "$REBUILD_OUT"; then
    ok "the AGENTBOX-FWD jump survived the rebuild"
else
    bad "the AGENTBOX-FWD jump did not survive the rebuild"
fi
if grep -q 'CONTAINER_AFTER_REBUILD' "$REBUILD_OUT"; then
    ok "a container still runs after a firewall rebuild"
else
    bad "no container could run after a firewall rebuild"
fi

printf -- '\n--- firewall-check on the Docker instance ---\n'
DFW_OUT="${TMP_ROOT}/dk-firewall.out"
run_bounded 300 "$DFW_OUT" "$AGENTBOX" firewall-check "$DOCKER_REPO"
dfw_rc=$BOUNDED_RC
cat "$DFW_OUT"
if [ "$dfw_rc" -eq 0 ]; then ok "firewall-check exited 0 on the Docker instance"; else bad "firewall-check exited ${dfw_rc} on the Docker instance"; fi
for check in policy-drop policy-drop-v6 forward-drop out-chain-first allowlist-rule \
             literal-ip-denied foreign-dns-denied egress-denied anthropic-allowed github-allowed \
             docker-user-jump docker-egress docker-allowed; do
    if grep -q "^PASS  ${check}" "$DFW_OUT"; then
        ok "firewall check ${check} (docker instance)"
    else
        bad "firewall check ${check} (docker instance)"
    fi
done

# ===========================================================================
step "12b. Node, Playwright and Rosetta"
# ===========================================================================

printf -- '--- node and npx ---\n'
NODE_OUT="${TMP_ROOT}/node.out"
"$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -lc 'node --version; npm --version' > "$NODE_OUT" 2>&1
cat "$NODE_OUT"
if grep -qE '^v22\.' "$NODE_OUT"; then
    ok "node --version is 22.x"
else
    bad "node --version is not 22.x"
fi

PW_OUT="${TMP_ROOT}/playwright.out"
run_bounded 300 "$PW_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- \
    bash -lc 'npx --yes playwright --version'
cat "$PW_OUT"
if grep -qiE 'Version [0-9]+\.[0-9]+' "$PW_OUT"; then
    ok "npx playwright --version printed a version"
else
    bad "npx playwright --version printed no version"
fi

printf -- '\n--- a Playwright system library is installed ---\n'
NSS_OUT="${TMP_ROOT}/libnss3.out"
dguest bash -c 'dpkg -s libnss3 2>&1 | grep -E "^(Package|Status):"' > "$NSS_OUT" 2>&1
cat "$NSS_OUT"
if grep -q 'Status: install ok installed' "$NSS_OUT"; then
    ok "libnss3 is installed, so install-deps really ran"
else
    bad "libnss3 is not installed"
fi

printf -- '\n--- python3-venv and pip, for pytest-playwright ---\n'
PY3_OUT="${TMP_ROOT}/py3.out"
dguest bash -c 'python3 -m venv --help >/dev/null 2>&1 && echo VENV_OK; python3 -m pip --version 2>&1 | head -1' > "$PY3_OUT" 2>&1
cat "$PY3_OUT"
if grep -q 'VENV_OK' "$PY3_OUT"; then
    ok "python3 -m venv is available"
else
    bad "python3 -m venv is not available"
fi
if grep -q '^pip ' "$PY3_OUT"; then
    ok "python3 -m pip is available"
else
    bad "python3 -m pip is not available"
fi

printf -- '\n--- Rosetta runs a linux/amd64 image ---\n'
ROS_OUT="${TMP_ROOT}/rosetta.out"
run_bounded 300 "$ROS_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
ls -l /proc/sys/fs/binfmt_misc/ 2>&1 | head -5
docker run --rm --platform linux/amd64 alpine:3 uname -m
'
cat "$ROS_OUT"
if grep -qx 'x86_64' "$ROS_OUT"; then
    ok "a linux/amd64 container reports x86_64, so Rosetta is doing the work"
else
    bad "a linux/amd64 container did not report x86_64"
fi

printf -- '\n--- the names added to the base allowlist are reachable under it ---\n'
# Provisioning downloads with the firewall stopped, so a name it needed could
# be missing from allowlist.base and nothing would notice until an agent tried
# to use it later. These are checked from inside the running guest, under the
# standing deny. Any HTTP status counts: an answer proves the connection was
# permitted, and 401 or 403 from a registry is an answer.
AL_OUT="${TMP_ROOT}/allowlist-reach.out"
# Each name is tried up to six times. That is not papering over flakiness: the
# allowlist pins addresses and several of these names sit behind CDNs that hand
# out one address from a rotating pool, so a single attempt tests the pool
# lottery rather than the allowlist. Six attempts against a set holding most of
# a pool is the shape a real download has, and a name that is genuinely absent
# still fails all six.
# shellcheck disable=SC2016  # $u and $code must expand in the guest, not here.
run_bounded 600 "$AL_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
for u in http://ports.ubuntu.com/ \
         https://download.docker.com/linux/ubuntu/gpg \
         https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt \
         https://cdn.playwright.dev/ \
         https://ghcr.io/v2/ \
         https://auth.docker.io/ \
         https://registry-1.docker.io/v2/; do
    code=000
    for _try in 1 2 3 4 5 6; do
        code=$(curl -sS -m 12 -o /dev/null -w "%{http_code}" "$u" 2>/dev/null || true)
        [ -n "$code" ] && [ "$code" != 000 ] && break
        sleep 2
    done
    printf "REACH %s %s\n" "${code:-000}" "$u"
done
'
grep '^REACH' "$AL_OUT" || cat "$AL_OUT"
for host in ports.ubuntu.com download.docker.com nodejs.org cdn.playwright.dev ghcr.io auth.docker.io registry-1.docker.io; do
    if grep -E "^REACH [1-5][0-9][0-9] " "$AL_OUT" | grep -q -- "${host}"; then
        ok "allowlisted and reachable: ${host}"
    else
        bad "allowlisted but NOT reachable: ${host}"
    fi
done

printf -- '\n--- and a name that is not on it still is not ---\n'
NAL_OUT="${TMP_ROOT}/allowlist-negative.out"
dguest bash -c 'curl -sS -m 8 -o /dev/null -w "%{http_code}" https://cdn.quay.io/ 2>&1; echo ""' > "$NAL_OUT" 2>&1
cat "$NAL_OUT"
if grep -qE '^(000)?$|Could not|refused|prohibited|unreachable|Failed' "$NAL_OUT"; then
    ok "cdn.quay.io, left commented out in allowlist.base, is refused"
else
    bad "cdn.quay.io answered although it is not on the allowlist"
fi

printf -- '\n--- tear the stack down ---\n'
dguest bash -c 'cd /tmp/abx-stack && docker compose down 2>&1 | tail -2; docker network rm abxnet >/dev/null 2>&1; true'

# ===========================================================================
step "13. destroy the Docker instance"
# ===========================================================================

"$AGENTBOX" destroy "$DOCKER_INSTANCE"
rc=$?
if [ "$rc" -eq 0 ]; then ok "agentbox destroy exited 0 for the Docker instance"; else bad "agentbox destroy exited ${rc} for the Docker instance"; fi

printf -- '\n--- limactl list ---\n'
"$LIMACTL" list 2>&1
if "$LIMACTL" list --quiet 2>/dev/null | grep -qxF "$DOCKER_INSTANCE"; then
    bad "${DOCKER_INSTANCE} is still listed after destroy"
else
    ok "${DOCKER_INSTANCE} is gone from limactl list"
fi

# ===========================================================================
hr
printf 'RESULT: %s passed, %s failed\n' "$PASS" "$FAIL"
hr
[ "$FAIL" -eq 0 ]
