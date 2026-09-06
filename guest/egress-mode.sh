#!/bin/bash
#
# agent-box — what egress mode this box is ACTUALLY in.
#
# Read the ruleset, not the file. The file is what somebody asked for; the
# ruleset is what the kernel is doing, and every reporter that told an operator
# "deny" because a file said so was one rebuild failure away from saying it
# about a box that permits everything.
#
# Prints three fields on one line:
#
#   live=<deny|observe|open|unknown>  what the ruleset is doing
#   file=<deny|observe|open|none>     what /etc/agent-box/egress-mode claims
#   detail=<text>                     empty when they agree; otherwise why not
#
# `unknown` is a real answer and is used whenever the ruleset cannot be read or
# does not match any of the three shapes. Guessing would be worse: this is the
# value the rest of the system decides whether to trust a box on.

set -uo pipefail

MODE_FILE="${AGENT_BOX_EGRESS_MODE_FILE:-/etc/agent-box/egress-mode}"
CHAIN_OUT="AGENTBOX-OUT"
IPT_WAIT=5

file_mode="none"
if [ -r "$MODE_FILE" ]; then
    case "$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null)" in
        deny) file_mode=deny ;; observe) file_mode=observe ;; open) file_mode=open ;;
        *) file_mode=none ;;
    esac
fi

live="unknown"
detail=""

# `sudo -n`: this runs from box-status.sh as the unprivileged guest user.
rules=$(sudo -n iptables -w "$IPT_WAIT" -S "$CHAIN_OUT" 2>/dev/null) || rules=""
policy=$(sudo -n iptables -w "$IPT_WAIT" -S 2>/dev/null | grep -- '-P OUTPUT') || policy=""

if [ -z "$rules" ] || [ -z "$policy" ]; then
    detail="the ruleset could not be read"
else
    tail_rule=$(printf '%s\n' "$rules" | tail -1)
    case "$policy" in
        *ACCEPT*)
            # Open requires BOTH: the policy open AND our chain present and
            # ending in an accept. A box whose firewall unit never ran also has
            # an ACCEPT policy, and calling that "open" would report an
            # unconfigured box as a deliberately configured one.
            if [ "$tail_rule" = "-A ${CHAIN_OUT} -j ACCEPT" ]; then
                live=open
            else
                live=unknown
                detail="the OUTPUT policy is ACCEPT but ${CHAIN_OUT} does not end in ACCEPT; the firewall may never have run"
            fi
            ;;
        *DROP*)
            if printf '%s\n' "$rules" | grep -q -- '-j LOG --log-prefix' \
                && [ "$tail_rule" = "-A ${CHAIN_OUT} -j ACCEPT" ]; then
                live=observe
            elif printf '%s\n' "$tail_rule" | grep -q -- '-j REJECT'; then
                live=deny
            else
                live=unknown
                detail="${CHAIN_OUT} matches none of the three known shapes"
            fi
            ;;
    esac
fi

if [ -z "$detail" ] && [ "$file_mode" != "none" ] && [ "$live" != "$file_mode" ]; then
    detail="the mode file says '${file_mode}' but the live ruleset is '${live}'"
fi
if [ -z "$detail" ] && [ "$file_mode" = "none" ] && [ "$live" != "unknown" ]; then
    detail="no mode file; reporting what the ruleset does"
fi

printf 'live=%s file=%s detail=%s\n' "$live" "$file_mode" "$detail"
