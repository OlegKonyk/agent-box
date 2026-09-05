#!/bin/bash
#
# agent-box — default-deny egress for the guest and for its containers.
#
# Derived from Anthropic's reference devcontainer firewall,
# https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh
# (fetched 2026-09-04). The structure has since diverged substantially; the
# differences that matter are listed in docs/decisions.md.
#
# The central property: THE LIVE RULESET IS NEVER REMOVED. The reference script
# flushes, rebuilds incrementally, and sets the policy to DROP at the end, which
# means every error path between the flush and the end leaves the machine wide
# open — and the rebuild itself runs with no rules at all. Here the new state is
# built off to one side and swapped in atomically:
#
#   * addresses go into a second ipset which is `ipset swap`ped with the live
#     one only once it is fully populated;
#   * rules go into three chains this script owns outright — AGENTBOX-IN,
#     AGENTBOX-OUT and AGENTBOX-FWD — which are replaced in one
#     `iptables-restore --noflush` transaction.
#
# The second property, new with the Docker profile: THIS SCRIPT OWNS ITS OWN
# CHAINS AND NOTHING ELSE. Docker installs six chains of its own (DOCKER,
# DOCKER-USER, DOCKER-FORWARD, DOCKER-CT, DOCKER-BRIDGE, DOCKER-INTERNAL) and
# does not recreate them if something else empties them — only a daemon restart
# does. An `iptables-restore` without `--noflush` replaces the entire filter
# table, so the previous version of this script silently cut every container off
# the network on each 15-minute tick once Docker was installed. `--noflush` with
# a file that declares only our own chains replaces exactly those and leaves
# every other chain, including Docker's, untouched. Verified in the guest, not
# assumed: see docs/decisions.md.
#
# So the rebuild runs *under* the standing deny. It needs only DNS to the
# configured resolvers and the GitHub ranges, both of which the standing ruleset
# already permits from the previous run. On the very first run there is no
# ruleset yet and the machine is briefly open, which is unavoidable and is why
# provisioning installs everything before this ever runs.
#
# Runs as root, from agent-box-firewall.service and its 15-minute timer, and —
# with --docker-hook — from docker.service's ExecStartPost.

# -E (errtrace) matters: without it the ERR trap installed below is NOT
# inherited by shell functions, command substitutions or subshells, and the
# whole fail-closed argument rests on that trap.
set -eEuo pipefail

BOX_DIR="${AGENT_BOX_DIR:-/opt/agent-box}"
CONFIG_DIR="${AGENT_BOX_CONFIG_DIR:-/opt/agent-box-config}"
ALLOWLIST_BASE="${BOX_DIR}/guest/allowlist.base"
# Mounted read-only from the host's ~/.config/agent-box. Optional.
ALLOWLIST_LOCAL="${CONFIG_DIR}/allowlist.local"

# Overridable so that test/smoke.sh can drive the failure path deliberately.
GH_META_URL="${AGENT_BOX_GH_META_URL:-https://api.github.com/meta}"

IPSET_NAME="allowed-domains"
IPSET_TMP="allowed-domains-new"

# The three chains this script owns. Everything it does to the filter table is
# confined to these plus the policies and the jumps that reach them.
CHAIN_IN="AGENTBOX-IN"
CHAIN_OUT="AGENTBOX-OUT"
CHAIN_FWD="AGENTBOX-FWD"
# Docker's documented place for user rules. FORWARD jumps here unconditionally,
# before DOCKER-FORWARD, and since Engine 28.0.1 the chain has no implicit
# RETURN of its own.
DOCKER_USER="DOCKER-USER"

# IFS is left alone deliberately: with IFS=$'\n\t', `log a b` would join its
# arguments with a newline instead of a space.
log() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# Chain plumbing
# ---------------------------------------------------------------------------

docker_installed() { command -v docker >/dev/null 2>&1; }

# The chain exists only once dockerd has run at least once.
chain_exists() {
    local ipt="$1" chain="$2"
    "$ipt" -n -L "$chain" >/dev/null 2>&1
}

# The interface the default route leaves by. Traffic forwarded out of anything
# else — a Docker bridge — is container-to-container or a published port, never
# egress, and must not be filtered by the allowlist.
uplink_iface() {
    ip route 2>/dev/null | awk '/^default/ {print $5; exit}'
}

ensure_chain() {
    local ipt="$1" chain="$2"
    chain_exists "$ipt" "$chain" || "$ipt" -N "$chain"
}

# `iptables -S CHAIN` prints the chain's own declaration first, so the Nth rule
# is the (N+1)th line. This returns the first rule, or the empty string.
first_rule() {
    local ipt="$1" chain="$2"
    "$ipt" -S "$chain" 2>/dev/null | sed -n '2p'
}

# Make `-j TARGET` rule 1 of CHAIN, idempotently, leaving no duplicates.
#
# Insert first and delete afterwards, never the other way round: deleting first
# would leave an instant in which the chain does not reach our rules at all, and
# for DOCKER-USER that instant is one in which containers are unfiltered.
ensure_jump_first() {
    local ipt="$1" chain="$2" target="$3" want line n
    want="-A ${chain} -j ${target}"
    if [ "$(first_rule "$ipt" "$chain")" != "$want" ]; then
        "$ipt" -I "$chain" 1 -j "$target"
    fi
    # Every further copy, removed from the top down. The first match is the one
    # just placed (or already correct) at rule 1; the second is a duplicate.
    while :; do
        line=$("$ipt" -S "$chain" 2>/dev/null | grep -n -x -F -- "$want" | sed -n '2p' | cut -d: -f1) || true
        [ -n "$line" ] || break
        n=$((line - 1))
        "$ipt" -D "$chain" "$n"
    done
}

# The jumps that make the three chains reachable. DOCKER-USER only exists once
# Docker has run, and this is called both before and after the restore, so a
# chain that appears in between is still picked up.
ensure_jumps() {
    local ipt="$1"
    ensure_jump_first "$ipt" INPUT  "$CHAIN_IN"
    ensure_jump_first "$ipt" OUTPUT "$CHAIN_OUT"
    if chain_exists "$ipt" "$DOCKER_USER"; then
        ensure_jump_first "$ipt" "$DOCKER_USER" "$CHAIN_FWD"
    fi
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
#
# These assert the mechanism, not one symptom. A check that only proves
# "example.com did not connect" passes just as happily when DNS is broken, when
# curl is missing, or when the ruleset was never applied at all.

# A literal address outside every allowlist and outside the host subnet, so it
# tests the REJECT rule rather than name resolution. 198.51.100.0/24 is
# TEST-NET-2 (RFC 5737) and is not routable anywhere.
LITERAL_BLOCKED_IP="198.51.100.42"
# A public resolver that is not the guest's configured one.
FOREIGN_RESOLVER="9.9.9.9"
# Small, and already needed as the container probe's own userland.
PROBE_IMAGE="alpine:3"

# busybox wget exits non-zero both when it cannot connect and when the server
# answers with an HTTP error, and the difference is the whole point of the
# check: an answered request means the connection was permitted. Prints
# "connected", "blocked" or "error: ..." on stdout.
container_probe() {
    local url="$1" out rc
    out=$(docker run --rm --network bridge "$PROBE_IMAGE" \
              wget -T 5 -q -O /dev/null "$url" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'connected'
    elif printf '%s' "$out" | grep -q 'server returned error'; then
        printf 'connected'
    elif printf '%s' "$out" | grep -qE "can't connect|bad address|network is unreachable|Connection refused|download timed out|Permission denied"; then
        printf 'blocked'
    else
        printf 'error: %s' "$(printf '%s' "$out" | tr '\n' ' ')"
    fi
}

verify() {
    local failures=0

    # --- the mechanism itself ---------------------------------------------

    if iptables -S 2>/dev/null | grep -qx -- '-P OUTPUT DROP'; then
        log "PASS  policy-drop        iptables OUTPUT policy is DROP"
    else
        log "FAIL  policy-drop        iptables OUTPUT policy is not DROP"
        failures=$((failures + 1))
    fi

    if ip6tables -S 2>/dev/null | grep -qx -- '-P OUTPUT DROP'; then
        log "PASS  policy-drop-v6     ip6tables OUTPUT policy is DROP"
    else
        log "FAIL  policy-drop-v6     ip6tables OUTPUT policy is not DROP"
        failures=$((failures + 1))
    fi

    if iptables -S 2>/dev/null | grep -qx -- '-P FORWARD DROP'; then
        log "PASS  forward-drop       iptables FORWARD policy is DROP"
    else
        log "FAIL  forward-drop       iptables FORWARD policy is not DROP"
        failures=$((failures + 1))
    fi

    if [ "$(first_rule iptables OUTPUT)" = "-A OUTPUT -j ${CHAIN_OUT}" ]; then
        log "PASS  out-chain-first    OUTPUT rule 1 jumps to ${CHAIN_OUT}"
    else
        log "FAIL  out-chain-first    OUTPUT rule 1 is not the ${CHAIN_OUT} jump"
        failures=$((failures + 1))
    fi

    if iptables -S "$CHAIN_OUT" 2>/dev/null | grep -q -- "--match-set ${IPSET_NAME} dst -j ACCEPT"; then
        log "PASS  allowlist-rule     the ${IPSET_NAME} ipset is referenced"
    else
        log "FAIL  allowlist-rule     no rule references the ${IPSET_NAME} ipset"
        failures=$((failures + 1))
    fi

    # --- the holes a name-based probe cannot see --------------------------

    # Bypassing DNS entirely: a literal address must still be refused.
    if curl -sS -m 5 -o /dev/null "https://${LITERAL_BLOCKED_IP}/" 2>/dev/null; then
        log "FAIL  literal-ip-denied  ${LITERAL_BLOCKED_IP} was reachable by address"
        failures=$((failures + 1))
    else
        log "PASS  literal-ip-denied  ${LITERAL_BLOCKED_IP} refused by address"
    fi

    # Port 53 to an arbitrary resolver is an exfiltration channel: a query name
    # is data. Only the configured resolvers may be reached.
    if dig +time=2 +tries=1 "@${FOREIGN_RESOLVER}" example.com >/dev/null 2>&1; then
        log "FAIL  foreign-dns-denied DNS to ${FOREIGN_RESOLVER} succeeded"
        failures=$((failures + 1))
    else
        log "PASS  foreign-dns-denied DNS to ${FOREIGN_RESOLVER} refused"
    fi

    # --- the allowlist does what it says ----------------------------------

    if curl -sS -m 5 -o /dev/null https://example.com 2>/dev/null; then
        log "FAIL  egress-denied      https://example.com was reachable"
        failures=$((failures + 1))
    else
        log "PASS  egress-denied      https://example.com blocked as expected"
    fi

    local code
    if code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' https://api.anthropic.com/ 2>/dev/null) \
        && [ -n "$code" ] && [ "$code" != "000" ]; then
        log "PASS  anthropic-allowed  https://api.anthropic.com/ returned HTTP ${code}"
    else
        log "FAIL  anthropic-allowed  https://api.anthropic.com/ did not answer"
        failures=$((failures + 1))
    fi

    if curl -sS -m 10 -o /dev/null https://github.com 2>/dev/null; then
        log "PASS  github-allowed     https://github.com reachable"
    else
        log "FAIL  github-allowed     https://github.com unreachable"
        failures=$((failures + 1))
    fi

    # --- containers obey the same allowlist -------------------------------
    #
    # Skipped, out loud, on an instance created without --docker: the checks
    # below are about a runtime that is not installed, and a silent skip reads
    # exactly like a pass.

    if ! docker_installed; then
        log "SKIP  docker-user-jump   Docker is not installed on this instance"
        log "SKIP  docker-egress      Docker is not installed on this instance"
        log "SKIP  docker-allowed     Docker is not installed on this instance"
    else
        if chain_exists iptables "$DOCKER_USER"; then
            if [ "$(first_rule iptables "$DOCKER_USER")" = "-A ${DOCKER_USER} -j ${CHAIN_FWD}" ]; then
                log "PASS  docker-user-jump   ${DOCKER_USER} rule 1 jumps to ${CHAIN_FWD}"
            else
                log "FAIL  docker-user-jump   ${DOCKER_USER} rule 1 is not the ${CHAIN_FWD} jump"
                failures=$((failures + 1))
            fi
        else
            log "FAIL  docker-user-jump   Docker is installed but ${DOCKER_USER} does not exist"
            failures=$((failures + 1))
        fi

        # Pulling the probe image is itself the registry test: the pull leaves
        # the guest through AGENTBOX-OUT and only succeeds if the Docker Hub
        # names are on the allowlist.
        local probe_pull=""
        if ! docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1; then
            probe_pull=$(docker pull -q "$PROBE_IMAGE" 2>&1) || probe_pull="FAILED: ${probe_pull}"
        fi
        if printf '%s' "$probe_pull" | grep -q '^FAILED'; then
            log "FAIL  docker-egress      could not pull ${PROBE_IMAGE}: ${probe_pull}"
            log "FAIL  docker-allowed     could not pull ${PROBE_IMAGE}"
            failures=$((failures + 2))
        else
            local r
            r=$(container_probe https://example.com)
            if [ "$r" = "blocked" ]; then
                log "PASS  docker-egress      a container could not reach https://example.com"
            else
                log "FAIL  docker-egress      a container reaching https://example.com: ${r}"
                failures=$((failures + 1))
            fi

            r=$(container_probe https://api.anthropic.com/)
            if [ "$r" = "connected" ]; then
                log "PASS  docker-allowed     a container reached https://api.anthropic.com/"
            else
                log "FAIL  docker-allowed     a container could not reach https://api.anthropic.com/: ${r}"
                failures=$((failures + 1))
            fi
        fi
    fi

    if [ "$failures" -ne 0 ]; then
        log "firewall verification: ${failures} check(s) FAILED"
        return 1
    fi
    log "firewall verification: all checks PASS"
    return 0
}

# `iptables -S` needs CAP_NET_ADMIN, so verification is a root operation too.
# `agentbox firewall-check` runs this under sudo for that reason.
if [ "${1:-}" = "--verify-only" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        log "ERROR: --verify-only must run as root (it reads the ruleset)" >&2
        exit 1
    fi
    verify
    exit $?
fi

if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: init-firewall.sh must run as root" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# The Docker hook
# ---------------------------------------------------------------------------
#
# docker.service's ExecStartPost. A daemon restart recreates whatever of its own
# chains are missing, and the 15-minute timer is far too coarse a net to catch
# the window: for up to fifteen minutes containers would forward through
# DOCKER-FORWARD with nothing of ours in front of it. This runs synchronously as
# part of the restart instead, so there is no window at all.
#
# It does one thing — put the AGENTBOX-FWD jump back at DOCKER-USER rule 1 — and
# deliberately does not rebuild anything, because a rebuild needs DNS and
# api.github.com and must never be on the critical path of starting a daemon.

docker_hook() {
    local ipt rc=0 uplink
    uplink=$(uplink_iface)

    for ipt in iptables ip6tables; do
        ensure_chain "$ipt" "$CHAIN_FWD"
        # An empty chain would let everything through to DOCKER-FORWARD. If the
        # full rebuild has not run yet, close the chain rather than leave it
        # open, and let the next timer tick fill it in properly.
        if [ -z "$(first_rule "$ipt" "$CHAIN_FWD")" ]; then
            log "WARN: ${CHAIN_FWD} (${ipt}) was empty; closing it until the next rebuild"
            if [ "$ipt" = "iptables" ] && [ -n "$uplink" ]; then
                "$ipt" -A "$CHAIN_FWD" ! -o "$uplink" -j RETURN
                "$ipt" -A "$CHAIN_FWD" -j REJECT --reject-with icmp-admin-prohibited
            elif [ "$ipt" = "iptables" ]; then
                "$ipt" -A "$CHAIN_FWD" -j REJECT --reject-with icmp-admin-prohibited
            else
                "$ipt" -A "$CHAIN_FWD" -j REJECT --reject-with icmp6-adm-prohibited
            fi
        fi
        "$ipt" -P FORWARD DROP
        if chain_exists "$ipt" "$DOCKER_USER"; then
            ensure_jump_first "$ipt" "$DOCKER_USER" "$CHAIN_FWD"
            if [ "$(first_rule "$ipt" "$DOCKER_USER")" = "-A ${DOCKER_USER} -j ${CHAIN_FWD}" ]; then
                log "docker-hook: ${ipt} ${DOCKER_USER} rule 1 is the ${CHAIN_FWD} jump"
            else
                log "ERROR: docker-hook could not place the ${CHAIN_FWD} jump in ${ipt} ${DOCKER_USER}" >&2
                rc=1
            fi
        else
            log "ERROR: docker-hook found no ${DOCKER_USER} chain in ${ipt}" >&2
            rc=1
        fi
    done
    return "$rc"
}

if [ "${1:-}" = "--docker-hook" ]; then
    docker_hook
    exit $?
fi

# ---------------------------------------------------------------------------
# Failing closed
# ---------------------------------------------------------------------------

standing_deny_in_place() {
    iptables -S 2>/dev/null | grep -qx -- '-P OUTPUT DROP'
}

# Nothing below tears down the live ruleset, so an error normally leaves the
# previous deny ruleset intact — which is already the safe outcome, and is
# recoverable, because the next timer tick can still reach DNS and GitHub to
# rebuild.
#
# Slamming everything shut to lo-only on any error would be strictly worse than
# that: the rebuild needs DNS and api.github.com, so a box cut down to loopback
# could never rebuild itself and would stay off the network until restarted. The
# hard close is therefore reserved for the case where it is the only safe option
# — an error with no standing deny ruleset to fall back on.
# Both the ERR trap and every explicit error exit go through here. Routing the
# explicit exits through the trap's logic is the point: a bare `exit 1` bypasses
# an ERR trap entirely, so on a first run — where there is no standing ruleset to
# fall back on — it would leave the machine with ACCEPT policies and no rules.
_close_and_exit() {
    local rc="$1" reason="$2"
    trap - ERR
    ipset destroy "$IPSET_TMP" 2>/dev/null || true
    if standing_deny_in_place; then
        log "ERROR: ${reason}; the previous deny ruleset is left in place" >&2
        exit "$rc"
    fi
    log "ERROR: ${reason}; there is no standing ruleset, so all egress is being closed" >&2

    # The gateway may not be known yet: the two earliest failures happen before
    # HOST_IP is assigned, so derive it here, and fall back to accepting port 22
    # from any source, which is safe behind the hypervisor's NAT.
    local gw="${HOST_IP:-}"
    [ -n "$gw" ] || gw=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}') || gw=""

    # Only the three builtin chains are flushed, never the whole table. `-F`
    # with no argument would empty Docker's chains too, and Docker recreates
    # them only on a daemon restart — so a hard close would leave a machine
    # whose containers stay broken long after the firewall recovered.
    local ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        "$ipt" -P INPUT DROP   2>/dev/null || true
        "$ipt" -P FORWARD DROP 2>/dev/null || true
        "$ipt" -P OUTPUT DROP  2>/dev/null || true
        "$ipt" -F INPUT   2>/dev/null || true
        "$ipt" -F FORWARD 2>/dev/null || true
        "$ipt" -F OUTPUT  2>/dev/null || true
        ensure_chain "$ipt" "$CHAIN_IN"  2>/dev/null || true
        ensure_chain "$ipt" "$CHAIN_OUT" 2>/dev/null || true
        ensure_chain "$ipt" "$CHAIN_FWD" 2>/dev/null || true
        "$ipt" -F "$CHAIN_IN"  2>/dev/null || true
        "$ipt" -F "$CHAIN_OUT" 2>/dev/null || true
        "$ipt" -F "$CHAIN_FWD" 2>/dev/null || true
        "$ipt" -A "$CHAIN_IN"  -i lo -j ACCEPT 2>/dev/null || true
        "$ipt" -A "$CHAIN_OUT" -o lo -j ACCEPT 2>/dev/null || true
    done

    # Closing egress must not also lock the operator out. Lima reaches this
    # guest over TCP to port 22, so a lo-only ruleset drops both new
    # `limactl shell` connections and any session already open — including the
    # one needed to run the recovery printed below. These three rules keep that
    # door open without opening egress: no NEW outbound connection is permitted,
    # only replies on connections that already exist.
    iptables -A "$CHAIN_IN"  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -A "$CHAIN_OUT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    if [ -n "$gw" ]; then
        iptables -A "$CHAIN_IN" -s "${gw}/32" -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    else
        iptables -A "$CHAIN_IN" -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    fi
    # Containers, if any, are cut off with everything else.
    iptables  -A "$CHAIN_FWD" -j REJECT --reject-with icmp-admin-prohibited 2>/dev/null || true
    ip6tables -A "$CHAIN_FWD" -j REJECT --reject-with icmp6-adm-prohibited  2>/dev/null || true
    ensure_jumps iptables  2>/dev/null || true
    ensure_jumps ip6tables 2>/dev/null || true

    log "Egress is closed; SSH from the host still works." >&2
    log "Recovery: 'sudo iptables -P OUTPUT ACCEPT; sudo iptables -F', then 'sudo systemctl restart agent-box-firewall.service'." >&2
    log "If this instance runs Docker, add 'sudo systemctl restart docker' — flushing the table above empties Docker's own chains and only a daemon restart puts them back." >&2
    exit "$rc"
}

fail_closed() {
    local rc=$?
    _close_and_exit "$rc" "the rebuild failed (exit ${rc})"
}

# Use instead of `exit 1` anywhere after the trap is installed.
die_fw() {
    _close_and_exit 1 "$*"
}

trap fail_closed ERR

# ---------------------------------------------------------------------------
# Inputs: the allowlist, the resolvers, the host gateway, the uplink
# ---------------------------------------------------------------------------

read_allowlist() {
    local file="$1"
    [ -f "$file" ] || return 0
    sed -e 's/#.*$//' -e 's/[[:space:]]//g' "$file" \
        | grep -E '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || true
}

[ -f "$ALLOWLIST_BASE" ] || die_fw "allowlist not found at ${ALLOWLIST_BASE}"

DOMAINS=$(read_allowlist "$ALLOWLIST_BASE")
if [ -f "$ALLOWLIST_LOCAL" ]; then
    log "Reading local allowlist ${ALLOWLIST_LOCAL}"
    DOMAINS=$(printf '%s\n%s\n' "$DOMAINS" "$(read_allowlist "$ALLOWLIST_LOCAL")")
else
    log "No local allowlist at ${ALLOWLIST_LOCAL} (that is fine)"
fi
# `|| true` so an empty result reaches the explicit check below instead of
# killing the script through pipefail with no explanation.
DOMAINS=$(printf '%s\n' "$DOMAINS" | grep -v '^$' | sort -u || true)
[ -n "$DOMAINS" ] || die_fw "the allowlist resolved to zero domains"

log "Allowlisted domains:"
printf '%s\n' "$DOMAINS" | sed 's/^/  /'

# The only resolvers the guest may talk to. Without this restriction port 53 is
# an open channel to any host on the internet: a query name is data, and a
# lookup against an attacker-controlled resolver never touches an allowlisted
# address.
#
# Ubuntu may point /etc/resolv.conf at systemd-resolved on 127.0.0.53, in which
# case the addresses that actually leave the machine are the upstream servers in
# /run/systemd/resolve/resolv.conf, so both files are consulted. Docker reads
# the same second file for containers on the default bridge, which is why the
# forward chain permits exactly these addresses too.
collect_resolvers() {
    local f
    for f in /etc/resolv.conf /run/systemd/resolve/resolv.conf; do
        [ -r "$f" ] || continue
        awk '/^[[:space:]]*nameserver[[:space:]]/ {print $2}' "$f" || true
    done | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' \
         | grep -v '^127\.' \
         | sort -u || true
}

RESOLVERS=$(collect_resolvers)

HOST_IP=$(ip route | awk '/^default/ {print $3; exit}')
[ -n "$HOST_IP" ] || die_fw "failed to detect the default gateway"
log "Host gateway: ${HOST_IP}"

UPLINK=$(uplink_iface)
[ -n "$UPLINK" ] || die_fw "failed to detect the uplink interface"
log "Uplink interface: ${UPLINK}"

if [ -z "$RESOLVERS" ]; then
    # A loopback-only resolv.conf with no discoverable upstream: Lima's host
    # resolver lives on the gateway, so fall back to that rather than opening
    # port 53 to everything.
    RESOLVERS="$HOST_IP"
    log "No non-loopback resolver found; falling back to the gateway"
fi
log "Permitted resolvers:"
printf '%s\n' "$RESOLVERS" | sed 's/^/  /'

# ---------------------------------------------------------------------------
# Build the new address set beside the live one
# ---------------------------------------------------------------------------

# The live set must exist for `ipset swap` to work; -exist makes this a no-op
# on every run after the first.
ipset create "$IPSET_NAME" hash:net -exist
ipset destroy "$IPSET_TMP" 2>/dev/null || true
ipset create "$IPSET_TMP" hash:net

log "Fetching GitHub IP ranges from ${GH_META_URL}..."
gh_ranges=$(curl -sS -m 20 "$GH_META_URL" || true)
[ -n "$gh_ranges" ] || die_fw "failed to fetch GitHub IP ranges from ${GH_META_URL}"
printf '%s' "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null \
    || die_fw "the GitHub meta response is missing required fields"

# `|| true` on both pipelines: grep exits 1 when it matches nothing, and under
# pipefail that would abort the script. The explicit emptiness check below is
# what fails closed, with a message.
if command -v aggregate >/dev/null 2>&1; then
    gh_cidrs=$(printf '%s' "$gh_ranges" | jq -r '(.web + .api + .git)[]' | grep -E '^[0-9.]+/[0-9]+$' | aggregate -q || true)
else
    gh_cidrs=$(printf '%s' "$gh_ranges" | jq -r '(.web + .api + .git)[]' | grep -E '^[0-9.]+/[0-9]+$' | sort -u || true)
fi
[ -n "$gh_cidrs" ] || die_fw "GitHub meta yielded no IPv4 ranges"

gh_count=0
while read -r cidr; do
    [ -n "$cidr" ] || continue
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        die_fw "invalid CIDR from GitHub meta: ${cidr}"
    fi
    ipset add "$IPSET_TMP" "$cidr" -exist
    gh_count=$((gh_count + 1))
done < <(printf '%s\n' "$gh_cidrs")
log "Added ${gh_count} GitHub ranges"

# Resolve the way the applications resolve, and more than once.
#
# Two separate problems, both found by a smoke check that curls each
# allowlisted name from inside the guest under the standing deny.
#
# The first is that `dig` and the rest of the system do not agree. `dig` sends
# its query to the nameserver in resolv.conf — Lima's host resolver on the
# gateway — while curl, Node, apt and every other program go through glibc to
# systemd-resolved on 127.0.0.53, which has its own cache. For a name with
# several A records that barely matters, because the sets overlap. For
# cdn.playwright.dev, an Azure Front Door endpoint that answers with exactly
# ONE A record on a near-zero TTL, the two paths returned different addresses
# in the same second: `dig` saw 150.171.109.113 while curl connected to
# 150.171.109.70. The firewall pinned the first and rejected the second, and
# the symptom is indistinguishable from a name that was never on the allowlist.
# So `getent ahostsv4` — the same path the applications take — is unioned with
# `dig`, which still contributes the fuller multi-address answers.
#
# The second is rotation: a CDN hands out part of its pool per query, so one
# lookup per rebuild pins one slice of it for fifteen minutes. More passes,
# spaced past the TTL, collect more of the pool — spaced deliberately, because
# repeated lookups inside one short TTL are answered from the cache and see the
# same address every time.
#
# The pass count DEFAULTS TO ONE, which is a measurement rather than a
# preference. Three passes turned a first boot from 59 seconds into 611 —
# past Lima's own start budget, so `agentbox create` failed — and on the case
# that prompted all this they changed nothing, because the two-path union had
# already fixed it. Raise AGENT_BOX_RESOLVE_PASSES if a particular CDN needs
# the breadth and the extra boot time is acceptable.
RESOLVE_PASSES="${AGENT_BOX_RESOLVE_PASSES:-1}"
RESOLVE_GAP="${AGENT_BOX_RESOLVE_GAP:-3}"
# `getent` takes no timeout of its own and NSS can block for a long time while
# systemd-resolved is still coming up, which is exactly when this script first
# runs. Bounded, because a firewall rebuild that hangs delays the boot it is
# part of.
GETENT_TIMEOUT="${AGENT_BOX_GETENT_TIMEOUT:-3}"

# Every IPv4 address this guest could reach the name by, from both paths.
resolve_ipv4() {
    local d="$1"
    {
        dig +short +timeout=3 +tries=2 A "$d" 2>/dev/null || true
        timeout "$GETENT_TIMEOUT" getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' || true
    } | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | sort -u || true
}

resolved_any=0
pass=1
while [ "$pass" -le "$RESOLVE_PASSES" ]; do
    pass_seen=0
    while read -r domain; do
        [ -n "$domain" ] || continue
        ips=$(resolve_ipv4 "$domain")
        if [ -z "$ips" ]; then
            # One unresolvable name must not take the whole rebuild down; the
            # next timer tick retries, and the live set keeps its contents
            # until the swap. Reported once, not once per pass.
            [ "$pass" -eq 1 ] && log "WARN: could not resolve ${domain}; skipping"
            continue
        fi
        n=0
        while read -r ip; do
            [ -n "$ip" ] || continue
            # -exist makes a repeat harmless, which is what lets the passes
            # accumulate rather than conflict.
            ipset add "$IPSET_TMP" "$ip" -exist
            n=$((n + 1))
        done < <(printf '%s\n' "$ips")
        pass_seen=$((pass_seen + n))
        resolved_any=1
        [ "$pass" -eq 1 ] && log "Added ${n} address(es) for ${domain}"
    done < <(printf '%s\n' "$DOMAINS")
    if [ "$pass" -gt 1 ]; then
        log "Resolution pass ${pass}: ${pass_seen} address(es) seen"
    fi
    pass=$((pass + 1))
    [ "$pass" -le "$RESOLVE_PASSES" ] && sleep "$RESOLVE_GAP"
done

[ "$resolved_any" -eq 1 ] || die_fw "not a single allowlisted name resolved"
log "Address set holds $(ipset save "$IPSET_TMP" | grep -c '^add ' || true) entries after ${RESOLVE_PASSES} pass(es)"

# Atomic from the kernel's point of view: rules referencing the set start
# matching the new contents on the next packet, with no gap in between.
ipset swap "$IPSET_TMP" "$IPSET_NAME"
ipset destroy "$IPSET_TMP"
log "Address set swapped in"

# ---------------------------------------------------------------------------
# Apply the ruleset, one transaction per table
# ---------------------------------------------------------------------------

RULES=$(mktemp)
RULES6=$(mktemp)
trap 'rm -f "$RULES" "$RULES6"' EXIT

# The chains must exist, and be reached, BEFORE the restore sets the policies to
# DROP. On a first run they are empty at this point and traffic falls through to
# the policy, which is still whatever it was; on every later run they already
# hold the previous ruleset, so there is no instant in which the box is both
# closed by policy and missing its accept rules.
for _ipt in iptables ip6tables; do
    ensure_chain "$_ipt" "$CHAIN_IN"
    ensure_chain "$_ipt" "$CHAIN_OUT"
    ensure_chain "$_ipt" "$CHAIN_FWD"
    ensure_jumps "$_ipt"
done

{
    printf '*filter\n'
    # Declaring a builtin chain under --noflush sets its policy and leaves its
    # rules alone; declaring a user chain replaces its contents outright. That
    # asymmetry is what this file is built around, and it is why the accept
    # rules live in chains of our own rather than in INPUT and OUTPUT directly.
    printf ':INPUT DROP [0:0]\n'
    printf ':FORWARD DROP [0:0]\n'
    printf ':OUTPUT DROP [0:0]\n'
    printf ':%s - [0:0]\n' "$CHAIN_IN"
    printf ':%s - [0:0]\n' "$CHAIN_OUT"
    printf ':%s - [0:0]\n' "$CHAIN_FWD"

    # --- inbound ---------------------------------------------------------
    printf -- '-A %s -i lo -j ACCEPT\n' "$CHAIN_IN"
    # Replies to connections already established in either direction.
    printf -- '-A %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n' "$CHAIN_IN"
    # `limactl shell`. Inbound, port 22 only, and only from the hypervisor's
    # gateway — not the whole subnet, which under vz is the host plus every
    # other VM on the machine.
    printf -- '-A %s -s %s/32 -p tcp --dport 22 -j ACCEPT\n' "$CHAIN_IN" "$HOST_IP"

    # --- the guest's own egress -------------------------------------------
    printf -- '-A %s -o lo -j ACCEPT\n' "$CHAIN_OUT"
    printf -- '-A %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n' "$CHAIN_OUT"

    # Reaching this guest's own containers is not egress. A published port is
    # served by docker-proxy (or by a DNAT to the container address), and either
    # way the packet leaves the host namespace through a Docker bridge, never
    # through the uplink. Named interfaces rather than address ranges, because
    # the bridge subnets are assigned by Docker and change per network.
    printf -- '-A %s -o docker0 -j ACCEPT\n' "$CHAIN_OUT"
    printf -- '-A %s -o br+ -j ACCEPT\n' "$CHAIN_OUT"

    # DNS, to the configured resolvers only.
    while read -r ns; do
        [ -n "$ns" ] || continue
        printf -- '-A %s -d %s/32 -p udp --dport 53 -j ACCEPT\n' "$CHAIN_OUT" "$ns"
        printf -- '-A %s -d %s/32 -p tcp --dport 53 -j ACCEPT\n' "$CHAIN_OUT" "$ns"
    done < <(printf '%s\n' "$RESOLVERS")

    # DHCP lease renewal on a long-running instance.
    printf -- '-A %s -p udp --dport 67:68 -j ACCEPT\n' "$CHAIN_OUT"

    # The allowlist. Deliberately no blanket accept toward the host subnet:
    # everything the guest legitimately needs from the host is either an
    # already-established connection, DNS above, or carried over vsock.
    printf -- '-A %s -m set --match-set %s dst -j ACCEPT\n' "$CHAIN_OUT" "$IPSET_NAME"

    # Rejected rather than dropped, so a blocked call fails immediately instead
    # of hanging until a timeout.
    printf -- '-A %s -j REJECT --reject-with icmp-admin-prohibited\n' "$CHAIN_OUT"

    # --- what containers may forward --------------------------------------
    #
    # Reached from DOCKER-USER rule 1, which FORWARD jumps to before anything of
    # Docker's own. Anything not leaving by the uplink — container to container,
    # a published port coming the other way — is returned unjudged, because it
    # is not egress and DOCKER-FORWARD is the chain that decides it.
    printf -- '-A %s ! -o %s -j RETURN\n' "$CHAIN_FWD" "$UPLINK"
    printf -- '-A %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n' "$CHAIN_FWD"
    while read -r ns; do
        [ -n "$ns" ] || continue
        printf -- '-A %s -d %s/32 -p udp --dport 53 -j ACCEPT\n' "$CHAIN_FWD" "$ns"
        printf -- '-A %s -d %s/32 -p tcp --dport 53 -j ACCEPT\n' "$CHAIN_FWD" "$ns"
    done < <(printf '%s\n' "$RESOLVERS")
    printf -- '-A %s -m set --match-set %s dst -j ACCEPT\n' "$CHAIN_FWD" "$IPSET_NAME"
    printf -- '-A %s -j REJECT --reject-with icmp-admin-prohibited\n' "$CHAIN_FWD"

    printf 'COMMIT\n'
} > "$RULES"

iptables-restore --noflush < "$RULES"
log "IPv4 ruleset applied"

# IPv6: no allowlist is maintained for it, so it is closed completely. Not
# best-effort — a failure here fails the unit, because a silently open v6 stack
# is a way around every rule above. Docker's daemon.json sets "ipv6": false, but
# Docker still creates its v6 chains, so the same chain-ownership rule applies:
# only ours are declared here.
{
    printf '*filter\n'
    printf ':INPUT DROP [0:0]\n'
    printf ':FORWARD DROP [0:0]\n'
    printf ':OUTPUT DROP [0:0]\n'
    printf ':%s - [0:0]\n' "$CHAIN_IN"
    printf ':%s - [0:0]\n' "$CHAIN_OUT"
    printf ':%s - [0:0]\n' "$CHAIN_FWD"
    printf -- '-A %s -i lo -j ACCEPT\n' "$CHAIN_IN"
    printf -- '-A %s -o lo -j ACCEPT\n' "$CHAIN_OUT"
    printf -- '-A %s -j REJECT --reject-with icmp6-adm-prohibited\n' "$CHAIN_FWD"
    printf 'COMMIT\n'
} > "$RULES6"

ip6tables-restore --noflush < "$RULES6"
log "IPv6 ruleset applied (closed)"

# Again, after the restore. The jumps live in chains this script does not own,
# so nothing above can have removed them — but DOCKER-USER may have come into
# existence while the rebuild was running, and this is where that is noticed.
ensure_jumps iptables
ensure_jumps ip6tables
log "Chain jumps in place"

log "Firewall configuration complete"
trap - ERR
verify
