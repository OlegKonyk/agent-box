#!/bin/bash
#
# agent-box — what an observe-mode box tried to reach.
#
# Root, in the guest, called by `agentbox egress-log`. Two sources, joined:
#
#   the kernel log   iptables' LOG target stamps every NEW connection that the
#                    allowlist did not match with a fixed prefix. That gives an
#                    address, a port and a time, and nothing else — a packet
#                    filter never sees the name.
#   dnsmasq's log    in observe mode dnsmasq runs with `log-queries`, so
#                    `reply <name> is <addr>` says which name produced the
#                    address. That is the only place the name exists.
#
# The join is best-effort by construction: an agent that connects to a literal
# address never resolved anything, and one that resolved a name an hour before
# connecting may have aged out of the window. Both cases are reported as what
# they are rather than guessed at.
#
# Everything printed goes through run-format.py first. The destinations an
# agent reached for are its output as much as anything it wrote.

set -eEuo pipefail

BOX_DIR="${AGENT_BOX_DIR:-/opt/agent-box}"
LOG_PREFIX="${AGENT_BOX_LOG_PREFIX:-agent-box-egress: }"
SINCE="1h"
FORMAT="text"

log() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --since)  SINCE="${2:?--since needs a duration}"; shift 2 ;;
        --format) FORMAT="${2:?--format needs text, json or allowlist}"; shift 2 ;;
        *) log "egress-log: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

case "$FORMAT" in text|json|allowlist) ;; *) log "egress-log: --format must be text, json or allowlist" >&2; exit 2 ;; esac

if [ "$(id -u)" -ne 0 ]; then
    log "egress-log: must run as root (it reads the kernel journal)" >&2
    exit 1
fi

MODE=deny
[ -r /etc/agent-box/egress-mode ] && MODE=$(tr -d '[:space:]' < /etc/agent-box/egress-mode)

KERN_RAW=$(journalctl -k --since "-${SINCE}" --no-pager -o short-iso 2>/dev/null \
           | grep -F "$LOG_PREFIX" || true)
DNS_RAW=$(journalctl -u dnsmasq --since "-${SINCE}" --no-pager -o short-iso 2>/dev/null \
          | grep -E ' (reply|cached) ' || true)

# The whole join and format in one place, because it is a table-building job and
# doing it in awk would be worse for everyone who reads it later.
KERN_RAW="$KERN_RAW" DNS_RAW="$DNS_RAW" MODE="$MODE" SINCE="$SINCE" FORMAT="$FORMAT" \
python3 - <<'PY' | python3 "${BOX_DIR}/guest/run-format.py" --scrub-stdin
import json, os, re, sys

kern = os.environ.get("KERN_RAW", "")
dns = os.environ.get("DNS_RAW", "")
mode = os.environ.get("MODE", "deny")
since = os.environ.get("SINCE", "1h")
fmt = os.environ.get("FORMAT", "text")

# addr -> the last name seen to resolve to it. dnsmasq prints one line per
# answer, oldest first, so the last writer wins and that is the most recent
# name the guest resolved to this address.
names = {}
for line in dns.splitlines():
    m = re.search(r"\s(?:reply|cached)\s+(\S+)\s+is\s+(\S+)\s*$", line)
    if not m:
        continue
    name, addr = m.group(1), m.group(2)
    if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", addr):
        names[addr] = name

# One entry per destination and port, which is the grain an allowlist works at.
seen = {}
for line in kern.splitlines():
    ts = line.split(" ", 1)[0]
    dst = re.search(r"\bDST=(\S+)", line)
    dpt = re.search(r"\bDPT=(\d+)", line)
    pro = re.search(r"\bPROTO=(\S+)", line)
    if not dst:
        continue
    key = (dst.group(1), dpt.group(1) if dpt else "-", pro.group(1) if pro else "-")
    e = seen.get(key)
    if e is None:
        seen[key] = {"count": 1, "first": ts, "last": ts}
    else:
        e["count"] += 1
        e["last"] = ts

rows = []
for (addr, port, proto), e in seen.items():
    rows.append({
        "address": addr, "port": port, "proto": proto,
        "count": e["count"], "first_seen": e["first"], "last_seen": e["last"],
        "name": names.get(addr),
    })
# Newest last, as the spec asks: the thing that just happened is at the bottom,
# where a terminal leaves it.
rows.sort(key=lambda r: (r["last_seen"], r["address"], r["port"]))

if fmt == "json":
    print(json.dumps({"mode": mode, "since": since, "destinations": rows}, indent=None))
    sys.exit(0)

if fmt == "allowlist":
    print("# agent-box egress-log --as-allowlist, mode=%s, window=%s" % (mode, since))
    print("# Append what you want to ~/.config/agent-box/guest/allowlist.local.")
    if not rows:
        print("# Nothing was logged in this window.")
        sys.exit(0)
    named, bare = [], []
    for r in rows:
        (named if r["name"] else bare).append(r)
    if named:
        print("# Names. These are what the guest resolved before connecting.")
        for n in sorted({r["name"] for r in named}):
            print(n)
    if bare:
        print("#")
        print("# Addresses with no name: the agent connected to these without")
        print("# resolving anything in the window, so nothing here says WHAT they")
        print("# are. That is a judgement call and it is yours - check each one")
        print("# before you allow it, or widen the window and look again.")
        for r in sorted({(r["address"], r["port"]) for r in bare}):
            print("# %s  (port %s)" % (r[0], r[1]))
    sys.exit(0)

if mode != "observe":
    print("egress mode is '%s', so nothing is being logged." % mode)
    print("Only 'observe' records what the box tries to reach.")
    print("")
if not rows:
    print("No non-allowlisted connections logged in the last %s." % since)
    sys.exit(0)

print("%-39s %-6s %-5s %7s  %-20s %s" % ("DESTINATION", "PORT", "PROTO", "COUNT", "LAST SEEN", "NAME"))
for r in rows:
    print("%-39s %-6s %-5s %7d  %-20s %s" % (
        r["address"], r["port"], r["proto"], r["count"], r["last_seen"], r["name"] or "-"))
print("")
print("%d destination(s) in the last %s. A dash means the guest did not resolve" % (len(rows), since))
print("a name for that address in this window.")
PY
