#!/bin/bash
#
# agent-box — write this box's egress mode.
#
# Root, in the guest, called by `agentbox egress <repo> <mode>`. It writes the
# file and nothing else: the rebuild that makes the mode true is a separate
# step, so that a failed write and a failed rebuild are different failures with
# different messages.
#
# The file is deliberately the only record the guest keeps. init-firewall.sh
# reads it on every run, provisioning writes it once and never again, and the
# host keeps its own copy so `status` can answer for a stopped box.

set -eEuo pipefail

MODE_FILE="${AGENT_BOX_EGRESS_MODE_FILE:-/etc/agent-box/egress-mode}"

log() { printf '%s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: set-egress-mode.sh must run as root" >&2
    exit 1
fi

MODE="${1:-}"
case "$MODE" in
    deny|observe|open) ;;
    *) log "ERROR: expected deny, observe or open, got '${MODE}'" >&2; exit 2 ;;
esac

install -d -m 0755 "$(dirname "$MODE_FILE")"
printf '%s\n' "$MODE" > "${MODE_FILE}.new"
chmod 0644 "${MODE_FILE}.new"
mv -f "${MODE_FILE}.new" "$MODE_FILE"
log "egress mode: ${MODE}"
