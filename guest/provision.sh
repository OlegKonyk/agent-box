#!/bin/bash
#
# agent-box — guest provisioning. Runs as root on every boot, from the
# `provision` block in lima/agent-box.yaml. Must be idempotent.
#
# Usage: provision.sh <guest-username> <guest-home-directory>
#
# Both arguments are supplied by Lima, which expands {{.User}} and {{.Home}}
# in the provision script. They are not guessed: Lima's builtin default guest
# home is /home/<user>.guest (with /home/<user>.linux as an accessible alias),
# not /home/<user>.

set -euo pipefail

BOX_DIR="${AGENT_BOX_DIR:-/opt/agent-box}"
# Read-only mount of the host's ~/.config/agent-box. May be empty.
CONFIG_DIR="${AGENT_BOX_CONFIG_DIR:-/opt/agent-box-config}"
BOX_USER="${1:?usage: provision.sh <username> <home>}"
BOX_HOME="${2:?usage: provision.sh <username> <home>}"

log() { printf '[agent-box provision] %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: must run as root" >&2
    exit 1
fi

if [ ! -d "$BOX_DIR/guest" ]; then
    log "ERROR: ${BOX_DIR} is not mounted (expected the agent-box checkout)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 0. Network access during provisioning
# ---------------------------------------------------------------------------
#
# Provisioning re-runs on every `limactl start`. From the second boot onward the
# firewall service is enabled and comes up at multi-user.target, and
# archive.ubuntu.com is not on the allowlist — so any apt work on a later boot
# would fail and take the whole start down with it. Whenever there is genuinely
# something to download, the firewall is stopped for the duration and started
# again at the end. When there is nothing to do, it is never touched.

FIREWALL_UNIT="agent-box-firewall.service"
FIREWALL_WAS_STOPPED=0

open_network_for_provisioning() {
    [ "$FIREWALL_WAS_STOPPED" -eq 0 ] || return 0
    if systemctl is-active --quiet "$FIREWALL_UNIT" 2>/dev/null; then
        log "Stopping ${FIREWALL_UNIT} for the duration of the downloads"
        systemctl stop "$FIREWALL_UNIT" || true
        # Stopping a oneshot unit does not undo its rules.
        iptables -P INPUT ACCEPT   2>/dev/null || true
        iptables -P FORWARD ACCEPT 2>/dev/null || true
        iptables -P OUTPUT ACCEPT  2>/dev/null || true
        iptables -F 2>/dev/null || true
        FIREWALL_WAS_STOPPED=1
    fi
}

# Opening the network above is the same shape as the failure this project fixed
# in init-firewall.sh, just moved into the provisioner: from here to the restart
# at the very end, any failure under `set -e` would leave the VM with no rules
# and ACCEPT policies. agent-run refuses to run in that state, but it is exactly
# the state someone opens `agentbox shell` to debug in — with unrestricted
# egress. So the window is closed on the way out, whatever the exit status.
close_network_on_exit() {
    local rc=$?
    trap - EXIT
    [ "$FIREWALL_WAS_STOPPED" -eq 1 ] || exit "$rc"
    if [ "$rc" -eq 0 ]; then
        exit "$rc"
    fi
    log "Provisioning failed (exit ${rc}) with the firewall stopped; restoring it"
    if systemctl restart "$FIREWALL_UNIT"; then
        log "Firewall restored"
    else
        log "ERROR: could not restart ${FIREWALL_UNIT}; closing all egress instead" >&2
        local gw
        gw=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}') || gw=""
        iptables -P INPUT DROP   2>/dev/null || true
        iptables -P FORWARD DROP 2>/dev/null || true
        iptables -P OUTPUT DROP  2>/dev/null || true
        iptables -F 2>/dev/null || true
        iptables -A INPUT -i lo -j ACCEPT  2>/dev/null || true
        iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
        # Same reasoning as the hard close in init-firewall.sh: egress stays
        # shut, but the operator can still get in to see why. A VM that failed
        # to provision is exactly the one someone needs a shell on.
        iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        if [ -n "$gw" ]; then
            iptables -A INPUT -s "${gw}/32" -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
        else
            iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
        fi
        log "Egress is closed; SSH from the host still works." >&2
    fi
    exit "$rc"
}
trap close_network_on_exit EXIT

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------

# tmux is not decoration: `agentbox run` is detached by default and every
# interactive session is meant to be left and come back to, so a box without it
# has no way to hold a run that outlives the shell that started it.
# procps is not decoration either: `agentbox stop-run` finds the CLI by walking
# the pane's process tree with pgrep, and without it only the wrapper script is
# signalled — the model never sees the interrupt, the wait runs its full course
# and the session is killed mid-write.
REQUIRED_PKGS=(iptables ipset dnsutils jq curl git ca-certificates tmux procps)
# `aggregate` merges the GitHub CIDR list; the firewall works without it.
OPTIONAL_PKGS=(aggregate)

missing=()
for pkg in "${REQUIRED_PKGS[@]}" "${OPTIONAL_PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$' || missing+=("$pkg")
done

if [ ${#missing[@]} -gt 0 ]; then
    log "Installing: ${missing[*]}"
    open_network_for_provisioning
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=180 update
    apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends "${REQUIRED_PKGS[@]}"
    # Optional packages best-effort, so a missing one cannot fail the boot.
    apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends "${OPTIONAL_PKGS[@]}" \
        || log "WARN: optional packages unavailable; continuing"
else
    log "All packages already present"
fi

# ---------------------------------------------------------------------------
# 2. Optional corporate CA
# ---------------------------------------------------------------------------
#
# A TLS-intercepting proxy re-signs every connection with its own root. Without
# that root in the trust store, both curl and Node reject everything. The file
# comes from the host's ~/.config/agent-box/ca.pem through the read-only config
# mount; it is never copied into this repository.

CA_SRC=""
if [ -f "${CONFIG_DIR}/ca.pem" ]; then
    CA_SRC="${CONFIG_DIR}/ca.pem"
fi

NODE_CA_LINE=""
if [ -n "$CA_SRC" ]; then
    log "Installing extra CA from ${CA_SRC}"
    install -m 0644 "$CA_SRC" /usr/local/share/ca-certificates/agent-box-extra-ca.crt
    update-ca-certificates
    NODE_CA_LINE='NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt'
else
    if [ -f /usr/local/share/ca-certificates/agent-box-extra-ca.crt ]; then
        log "Removing a previously installed extra CA"
        rm -f /usr/local/share/ca-certificates/agent-box-extra-ca.crt
        update-ca-certificates --fresh >/dev/null 2>&1 || true
    fi
    log "No extra CA supplied"
fi

# ---------------------------------------------------------------------------
# 3. Guest environment
# ---------------------------------------------------------------------------
#
# Lima does not expand template variables in the template's `env:` block, so
# CLAUDE_CONFIG_DIR — which needs the guest home — is set here instead. Lima
# rewrites /etc/environment during boot, before provisioning runs, so appending
# on every boot is both necessary and safe.

ENV_MARKER='# --- agent-box ---'
if grep -qF "$ENV_MARKER" /etc/environment 2>/dev/null; then
    sed -i "/${ENV_MARKER}/,\$d" /etc/environment
fi
{
    printf '%s\n' "$ENV_MARKER"
    printf 'CLAUDE_CONFIG_DIR=%s/.claude\n' "$BOX_HOME"
    # No background self-update. An update is a new binary arriving over the
    # network in the middle of a run, quietly changing the thing under test,
    # and if the download were ever blocked the first symptom would be a slow
    # start nobody can account for. `agentbox update <repo>` does it on
    # purpose instead; `claude update` by hand still works.
    printf 'DISABLE_AUTOUPDATER=1\n'
    [ -n "$NODE_CA_LINE" ] && printf '%s\n' "$NODE_CA_LINE"
} >> /etc/environment

cat > /etc/profile.d/agent-box.sh <<EOF
# Managed by agent-box provisioning. Do not edit.
export PATH="\$HOME/.local/bin:\$PATH"
export CLAUDE_CONFIG_DIR="${BOX_HOME}/.claude"
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export DISABLE_AUTOUPDATER=1
EOF
[ -n "$NODE_CA_LINE" ] && printf 'export %s\n' "$NODE_CA_LINE" >> /etc/profile.d/agent-box.sh
chmod 0644 /etc/profile.d/agent-box.sh

install -d -m 0700 -o "$BOX_USER" -g "$BOX_USER" "${BOX_HOME}/.config/agent-box"
install -d -m 0700 -o "$BOX_USER" -g "$BOX_USER" "${BOX_HOME}/.agent-box"
install -d -m 0700 -o "$BOX_USER" -g "$BOX_USER" "${BOX_HOME}/.agent-box/runs"
install -d -m 0700 -o "$BOX_USER" -g "$BOX_USER" "${BOX_HOME}/.agent-box/sessions"
install -d -m 0700 -o "$BOX_USER" -g "$BOX_USER" "${BOX_HOME}/.agent-box/briefs"

# A generic git identity, so a brief that asks the agent to commit works instead
# of stopping at "Please tell me who you are" or improvising one. Deliberately
# not the host user's name or address: nothing identifying belongs in a commit
# the agent makes. --system, so it applies without writing into the work repo.
git config --system user.name  'agent-box'
git config --system user.email 'agent-box@localhost'
git config --system init.defaultBranch main
# /work is owned by the host uid over virtiofs; without this git refuses to
# operate in it as "dubious ownership".
git config --system --replace-all safe.directory '/work'

# ---------------------------------------------------------------------------
# 4. Claude Code, installed as the unprivileged guest user
# ---------------------------------------------------------------------------
#
# The CLI refuses --dangerously-skip-permissions when running as root, which is
# the whole reason the agent runs as this user rather than root.

CLAUDE_BIN="${BOX_HOME}/.local/bin/claude"
if [ -x "$CLAUDE_BIN" ]; then
    log "Claude Code already installed at ${CLAUDE_BIN}"
else
    log "Installing Claude Code as ${BOX_USER}"
    open_network_for_provisioning
    # pipefail inside the inner shell: without it, a failed curl feeds an empty
    # script to bash, which exits 0 and reports a successful install that did
    # nothing. The failure would otherwise surface much later, as "claude is not
    # on PATH" from a run, with nothing pointing back at the download.
    sudo -u "$BOX_USER" -H bash -lc 'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash'
    if [ ! -x "$CLAUDE_BIN" ]; then
        log "ERROR: the installer finished but ${CLAUDE_BIN} is not executable" >&2
        exit 1
    fi
    log "Claude Code installed at ${CLAUDE_BIN}"
fi

# ---------------------------------------------------------------------------
# 5. The egress firewall, as a service and a refresh timer
# ---------------------------------------------------------------------------
#
# Allowlisted names are resolved to addresses, and CDN addresses rotate, so the
# rules are rebuilt every 15 minutes.

cat > /etc/systemd/system/agent-box-firewall.service <<EOF
[Unit]
Description=agent-box egress allowlist
After=network-online.target
Wants=network-online.target
RequiresMountsFor=${BOX_DIR}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${BOX_DIR}/guest/init-firewall.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# A RemainAfterExit oneshot ignores a plain `start` once it is active, so the
# timer drives a second unit that restarts it.
cat > /etc/systemd/system/agent-box-firewall-refresh.service <<EOF
[Unit]
Description=Rebuild the agent-box egress allowlist
RequiresMountsFor=${BOX_DIR}

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart agent-box-firewall.service
EOF

cat > /etc/systemd/system/agent-box-firewall.timer <<'EOF'
[Unit]
Description=Refresh the agent-box egress allowlist every 15 minutes

[Timer]
OnBootSec=15min
OnUnitActiveSec=15min
Unit=agent-box-firewall-refresh.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

# Started last, so that the package and Claude Code downloads above are not
# blocked by the very rules being installed. `restart` rather than `start`,
# because a RemainAfterExit oneshot that is already active ignores `start` —
# which on a later boot would leave the rules from before the stop above.
log "Enabling the egress firewall"
systemctl enable "$FIREWALL_UNIT"
systemctl restart "$FIREWALL_UNIT"
systemctl enable --now agent-box-firewall.timer

# ---------------------------------------------------------------------------
# 6. Personal configuration and plugins, as the guest user, under the firewall
# ---------------------------------------------------------------------------
#
# Both steps run AFTER the firewall is back up, deliberately. The plugin
# install pulls from GitHub, which the allowlist permits through the ranges
# fetched from api.github.com/meta, so this is also a live test of that rule on
# every first boot: if the GitHub range rule ever breaks, the install says so
# here rather than the next time someone needs it.
#
# Neither is allowed to fail the boot. The isolation properties — the mounts,
# the firewall, the non-root user, the token handling — do not depend on either
# one, and a VM that will not start because a marketplace was unreachable is
# worse than a VM without a plugin.

# A login shell, so /etc/profile.d/agent-box.sh (written above) supplies PATH
# and CLAUDE_CONFIG_DIR. The arguments go through as arguments rather than
# being pasted into the command string, so nothing here depends on the paths
# being free of shell metacharacters.
run_as_box_user() {
    sudo -u "$BOX_USER" -H bash -lc 'exec "$@"' bash "$@"
}

log "Syncing personal Claude Code configuration from the host config mount"
run_as_box_user "${BOX_DIR}/guest/sync-claude-config.sh" \
    || log "WARN: sync-claude-config.sh exited non-zero; continuing"

log "Installing plugins listed in ${CONFIG_DIR}/plugins.txt, if any"
run_as_box_user "${BOX_DIR}/guest/install-plugins.sh" \
    || log "WARN: install-plugins.sh exited non-zero; run 'agentbox plugins <repo>' after 'agentbox token <repo>'"

log "Provisioning complete"
