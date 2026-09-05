#!/bin/bash
#
# agent-box — default-deny egress for the guest.
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
#   * rules are applied with a single `iptables-restore`, which replaces the
#     filter table as one transaction.
#
# So the rebuild runs *under* the standing deny. It needs only DNS to the
# configured resolvers and the GitHub ranges, both of which the standing ruleset
# already permits from the previous run. On the very first run there is no
# ruleset yet and the machine is briefly open, which is unavoidable and is why
# provisioning installs everything before this ever runs.
#
# Runs as root, from agent-box-firewall.service and its 15-minute timer.

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

# IFS is left alone deliberately: with IFS=$'\n\t', `log a b` would join its
# arguments with a newline instead of a space.
log() { printf '%s\n' "$*"; }

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

    if iptables -S 2>/dev/null | grep -q -- "--match-set ${IPSET_NAME} dst -j ACCEPT"; then
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

    iptables -P INPUT DROP   2>/dev/null || true
    iptables -P FORWARD DROP 2>/dev/null || true
    iptables -P OUTPUT DROP  2>/dev/null || true
    iptables -F 2>/dev/null || true
    iptables -A INPUT -i lo -j ACCEPT  2>/dev/null || true
    iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true

    # Closing egress must not also lock the operator out. Lima reaches this
    # guest over TCP to port 22, so a lo-only ruleset drops both new
    # `limactl shell` connections and any session already open — including the
    # one needed to run the recovery printed below. These three rules keep that
    # door open without opening egress: no NEW outbound connection is permitted,
    # only replies on connections that already exist.
    iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    if [ -n "$gw" ]; then
        iptables -A INPUT -s "${gw}/32" -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    else
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    fi

    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -P INPUT DROP   2>/dev/null || true
        ip6tables -P FORWARD DROP 2>/dev/null || true
        ip6tables -P OUTPUT DROP  2>/dev/null || true
        ip6tables -F 2>/dev/null || true
    fi
    log "Egress is closed; SSH from the host still works." >&2
    log "Recovery: 'sudo iptables -P OUTPUT ACCEPT; sudo iptables -F', then 'sudo systemctl restart agent-box-firewall.service'." >&2
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
# Inputs: the allowlist, the resolvers, the host gateway
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
# /run/systemd/resolve/resolv.conf, so both files are consulted.
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

resolved_any=0
while read -r domain; do
    [ -n "$domain" ] || continue
    ips=$(dig +short +timeout=3 +tries=2 A "$domain" | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || true)
    if [ -z "$ips" ]; then
        # One unresolvable name must not take the whole rebuild down; the next
        # timer tick retries, and the live set keeps its contents until the swap.
        log "WARN: could not resolve ${domain}; skipping"
        continue
    fi
    n=0
    while read -r ip; do
        [ -n "$ip" ] || continue
        ipset add "$IPSET_TMP" "$ip" -exist
        n=$((n + 1))
    done < <(printf '%s\n' "$ips")
    resolved_any=1
    log "Added ${n} address(es) for ${domain}"
done < <(printf '%s\n' "$DOMAINS")

[ "$resolved_any" -eq 1 ] || die_fw "not a single allowlisted name resolved"

# Atomic from the kernel's point of view: rules referencing the set start
# matching the new contents on the next packet, with no gap in between.
ipset swap "$IPSET_TMP" "$IPSET_NAME"
ipset destroy "$IPSET_TMP"
log "Address set swapped in"

# ---------------------------------------------------------------------------
# Apply the ruleset in one transaction
# ---------------------------------------------------------------------------

RULES=$(mktemp)
RULES6=$(mktemp)
trap 'rm -f "$RULES" "$RULES6"' EXIT

{
    printf '*filter\n'
    printf ':INPUT DROP [0:0]\n'
    printf ':FORWARD DROP [0:0]\n'
    printf ':OUTPUT DROP [0:0]\n'

    printf -- '-A INPUT -i lo -j ACCEPT\n'
    printf -- '-A OUTPUT -o lo -j ACCEPT\n'

    # Replies to connections already established in either direction.
    printf -- '-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n'
    printf -- '-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n'

    # `limactl shell`. Inbound, port 22 only, and only from the hypervisor's
    # gateway — not the whole subnet, which under vz is the host plus every
    # other VM on the machine.
    printf -- '-A INPUT -s %s/32 -p tcp --dport 22 -j ACCEPT\n' "$HOST_IP"

    # DNS, to the configured resolvers only.
    while read -r ns; do
        [ -n "$ns" ] || continue
        printf -- '-A OUTPUT -d %s/32 -p udp --dport 53 -j ACCEPT\n' "$ns"
        printf -- '-A OUTPUT -d %s/32 -p tcp --dport 53 -j ACCEPT\n' "$ns"
    done < <(printf '%s\n' "$RESOLVERS")

    # DHCP lease renewal on a long-running instance.
    printf -- '-A OUTPUT -p udp --dport 67:68 -j ACCEPT\n'

    # The allowlist. Deliberately no blanket accept toward the host subnet:
    # everything the guest legitimately needs from the host is either an
    # already-established connection, DNS above, or carried over vsock.
    printf -- '-A OUTPUT -m set --match-set %s dst -j ACCEPT\n' "$IPSET_NAME"

    # Rejected rather than dropped, so a blocked call fails immediately instead
    # of hanging until a timeout.
    printf -- '-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited\n'
    printf 'COMMIT\n'
} > "$RULES"

iptables-restore < "$RULES"
log "IPv4 ruleset applied"

# IPv6: no allowlist is maintained for it, so it is closed completely. Not
# best-effort — a failure here fails the unit, because a silently open v6 stack
# is a way around every rule above.
{
    printf '*filter\n'
    printf ':INPUT DROP [0:0]\n'
    printf ':FORWARD DROP [0:0]\n'
    printf ':OUTPUT DROP [0:0]\n'
    printf -- '-A INPUT -i lo -j ACCEPT\n'
    printf -- '-A OUTPUT -o lo -j ACCEPT\n'
    printf 'COMMIT\n'
} > "$RULES6"

ip6tables-restore < "$RULES6"
log "IPv6 ruleset applied (closed)"

log "Firewall configuration complete"
trap - ERR
verify
