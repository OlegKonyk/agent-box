# agent-box

A disposable Linux VM that runs Claude Code against exactly one repository,
with deny-by-default outbound network and a personal OAuth token that never
touches the host disk.

Built for running an agent on generic end-to-end test repositories from a
work-managed Mac, under a personal subscription, without either side leaking
into the other.

## The threat model, both ways

The isolation has to cut in two directions, and most setups only do one. The
agent must not see the host: not other repositories, not SSH keys, not browser
profiles, not the corporate filesystem — so the VM mounts one repository and
nothing else, and Lima fixes mounts at create time, which means the answer to
"can it see X" is decided once and cannot drift. In the other direction, a
personal subscription token must not end up on a work-managed machine's disk,
in its backups, or in its logs — so the token is typed once, piped straight
into the guest, and dies with the disk image. Between the two sits the egress
allowlist: the agent can reach the model, GitHub, npm and PyPI, and nothing
else, so a repository's contents cannot be posted somewhere by accident.

## Install

```
brew install lima gitleaks
git clone <this repo> ~/dev/agent-box
```

Then follow **[docs/first-run.md](docs/first-run.md)**, which covers sign-off,
minting the token, host-side configuration, and the checks that prove it works.

## Commands

One instance per repository, named `agent-box-<repo basename>`.

| Command | What it does |
|---|---|
| `agentbox preflight <repo>` | Scan a repo for secrets and configured terms. Exit 1 on findings. |
| `agentbox create <repo>` | Preflight, then create and start that repo's VM. |
| `agentbox start <repo>` | Preflight, then start an existing VM. |
| `agentbox token <repo>` | Read an OAuth token from the terminal into the VM. Never echoed, never stored on the host. |
| `agentbox verify-auth <repo>` | Prove the token authenticates, with one real model call. |
| `agentbox claude <repo> [args]` | Interactive Claude Code in the VM, in `/work`. Arguments pass through to the CLI. |
| `agentbox shell <repo>` | Interactive shell in the VM, in `/work`. |
| `agentbox run <repo> <brief.md> [--model M]` | Run one headless task from a brief. Default model `sonnet`. |
| `agentbox plugins <repo> [--update]` | Apply `plugins.txt` inside the VM. |
| `agentbox update <repo>` | Update Claude Code inside the VM, printing the version before and after. |
| `agentbox stop <repo\|name>` | Stop the VM. |
| `agentbox destroy <repo\|name>` | Stop and delete the VM, and remind you to revoke the token. |
| `agentbox status` | List all Lima instances. |
| `agentbox firewall-check <repo\|name>` | Re-run the egress verification inside the VM. |

The last three also take a bare instance name, so a VM can still be shut down
and deleted after its repository directory is gone.

## Layout

```
bin/agentbox            the host CLI; the only thing you run directly
lima/agent-box.yaml     the VM: three mounts (two read-only), no home directory
guest/provision.sh      first-boot setup, as root
guest/init-firewall.sh  the egress allowlist, as root, on a 15-minute timer
guest/allowlist.base    generic allowed domains, one per line
guest/lib.sh            the preconditions and token handling the next three share
guest/agent-run.sh      one headless task, as the non-root guest user
guest/claude-session.sh one interactive session, as the non-root guest user
guest/verify-auth.sh    one small model call, to prove the token works
guest/sync-claude-config.sh  carry named config files in; mark /work trusted
guest/install-plugins.sh     apply plugins.txt inside the guest
host/preflight.sh       repository scan; reports paths only, never contents
templates/brief.md      the task brief to copy and fill in
test/smoke.sh           builds a real VM, checks it, destroys it
docs/first-run.md       sign-off, token, daily loop, decommissioning
docs/daily-use.md       the two modes, config carry-over, plugins, the friction
docs/decisions.md       why it is built this way, and what was rejected
```

Anything specific to where you work lives in `~/.config/agent-box/`, never in
this repository. It is split in two on purpose:

```
~/.config/agent-box/
  blocklist.txt              read on the host only, NEVER mounted
  guest/                     mounted read-only at /opt/agent-box-config
    allowlist.local          extra egress domains, one per line
    ca.pem                   corporate TLS-intercept root, if any
    plugins.txt              marketplaces to register, plugins to install
    plugin-dir/<name>/       plugin roots loaded per session, not installed
    claude/                  CLAUDE.md, settings.json, governor.json, rules/
```

- `~/.config/agent-box/guest/` is mounted read-only into the VM at
  `/opt/agent-box-config`.
- `~/.config/agent-box/blocklist.txt` holds the terms that must never leave. It
  is read on the host only and is **never** mounted, because it is the one file
  whose contents an agent must not see.

Both distinctions are deliberate: see [docs/decisions.md](docs/decisions.md).
What of `claude/` crosses into the guest, and what is refused, is in
[docs/daily-use.md](docs/daily-use.md).

## What this is not

The guest user has passwordless sudo, because Lima's provisioning needs it. An
agent that decided to disable its own firewall could. The firewall is a guard
rail against a capable tool doing something careless, not a sandbox against a
hostile one — the VM boundary is what protects the host.

The token never touches the host filesystem, but it is not sealed away from the
agent either: inside the VM the agent can read the token file and can write to
`/work`, which is the host's disk. Run transcripts are therefore kept in the
guest home and only a scrubbed summary crosses over, and every run is checked
afterwards for token fragments in the log and the diffs. That check is a
backstop, not a boundary. `docs/decisions.md` states the residual risk in full.

## Test

```
test/smoke.sh
```

Creates a real Lima instance from a throwaway repository, verifies the guest is
non-root, that `/work` is shared and `/opt/agent-box` is read-only, that the
host home directory is not mounted, that the firewall is active and blocking,
that Claude Code is installed, and that a run without a token is refused. Then
it destroys the instance. Lima's downloaded base images, cached under
`~/Library/Caches/lima/download`, are left in place.
