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
