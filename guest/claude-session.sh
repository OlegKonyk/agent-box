#!/bin/bash
#
# agent-box — an interactive Claude Code session inside the guest, at /work.
#
# Runs in the guest, as the unprivileged guest user. Invoked by
# `agentbox claude <repo> [claude args...]`.
#
# Usage: claude-session.sh [claude args...]
#
# This is the interactive half of the box. `agentbox run` is the headless half
# and gets a scrubbed summary, a branch and a leak check; this one hands the
# terminal straight to the CLI, which is what makes it useful and also what
# makes it unscrubbed — see docs/decisions.md. The preconditions are the same
# ones agent-run.sh insists on, from the same file, because "an interactive
# session" is not a reason to run an agent with the firewall down or with an
# API key quietly outranking the subscription token.

set -uo pipefail

die() { printf 'agent-box claude: %s\n' "$*" >&2; exit 1; }

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

WORK_DIR="${AGENT_BOX_WORK:-/work}"

abx_assert_environment die

[ -d "$WORK_DIR" ] || die "${WORK_DIR} is not mounted"

# Session-only plugin roots from the read-only host config mount.
PLUGIN_ARGS=()
mapfile -t PLUGIN_ARGS < <(abx_plugin_dir_args)
abx_report_plugin_dirs "${PLUGIN_ARGS[@]}"

abx_export_token

cd "$WORK_DIR" || die "cannot enter ${WORK_DIR}"

# exec, so the CLI owns the terminal and its exit status is the one the host
# sees. The token is in this process's environment and goes no further: it is
# not on the guest's disk outside the 0600 token file, not in argv, and not in
# anything written to /work.
exec claude "${PLUGIN_ARGS[@]}" "$@"
