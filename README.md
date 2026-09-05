# agent-box

A safe box for an unattended coding agent.

For anyone who wants to let an agent run unattended without handing it their
laptop.

The guarantee: the agent gets exactly one mounted repository and its own
subscription token, deny-by-default outbound network, no reach into the rest
of the host, no ability to push, and a scrubbed one-line summary as the only
thing that comes back.

## How it works

agent-box is a disposable Linux VM (Lima, on Apple's own virtualization
framework) with Claude Code installed inside it. `bin/agentbox` fixes its
mounts at creation time — the repository at `/work`, this checkout read-only,
and an optional host config directory — so "can the agent see X" is decided
once and cannot drift while the VM is running. The isolation cuts both ways:
the agent must not reach anything on the host beyond that one repository — not
other projects, not SSH keys, not browser profiles — and the subscription
token must not reach anything the agent writes. The agent runs with
`--dangerously-skip-permissions` and can write anywhere under `/work`, so its
transcript stays sealed inside the VM and only a scrubbed summary, checked for
fragments of the token, ever crosses to the host's disk. An egress allowlist
sits in the middle: the agent can reach the model, GitHub, npm and PyPI, and
nothing else, so a repository's contents cannot be posted somewhere by
accident.

## Before you point it at code you do not own

Get permission first, in writing, from whoever owns the repository and the
data in it. This tool enforces the technical boundary — one repository, one
token, no host access, no push — but it cannot get you permission to run an
agent against someone else's code, and nothing below substitutes for asking.
What to ask for, and a template, are in
**[docs/first-run.md](docs/first-run.md)**.

## Quick start

```
brew install lima gitleaks
git clone <this repo> ~/dev/agent-box
cd ~/dev/agent-box
./bin/agentbox create ~/dev/my-e2e-tests
./bin/agentbox token  ~/dev/my-e2e-tests        # paste a token from `claude setup-token`
./bin/agentbox verify-auth ~/dev/my-e2e-tests   # the only real proof it works
```

`create` takes a few minutes the first time, mostly downloading the Ubuntu
image. Full walkthrough, including what each step actually checks:
**[docs/first-run.md](docs/first-run.md)**.

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
docs/first-run.md       permission, token, daily loop, decommissioning
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
    ca.pem                   TLS-intercepting proxy root, if any
    plugins.txt              marketplaces to register, plugins to install
    plugin-dir/<name>/       plugin roots loaded per session, not installed
    claude/                  CLAUDE.md, settings.json, governor.json, rules/
```

- `~/.config/agent-box/guest/` is mounted read-only into the VM at
  `/opt/agent-box-config`.
- `~/.config/agent-box/blocklist.txt` is a local term blocklist: names,
  hostnames or codenames you never want to leave this machine. It is read on
  the host only and is **never** mounted, because it is the one file whose
  contents an agent must not see.

Both distinctions are deliberate: see [docs/decisions.md](docs/decisions.md).
What of `claude/` crosses into the guest, and what is refused, is in
[docs/daily-use.md](docs/daily-use.md).

## Limits and known weaknesses

- **The guest user has passwordless sudo.** Lima's provisioning needs it, so a
  capable agent could disable its own firewall. The firewall is a guard rail
  against carelessness, not a sandbox against a hostile tool — the VM boundary
  is what protects the host. Tracked as
  [issue #1](https://github.com/OlegKonyk/agent-box/issues/1).
- **The interactive session is not scrubbed.** `agentbox run` checks its
  output for token fragments before reporting success; `agentbox claude` hands
  you the terminal and cannot.
- **DNS resolves through the host's resolver.** The guest can resolve internal
  names it cannot connect to, and each lookup reaches the host's resolver with
  the VM as its origin. See "What the guest can still see: names" in
  [docs/decisions.md](docs/decisions.md).
- **MDM and corporate proxies are untested.** Some device-management profiles
  restrict the virtualization framework this depends on, and a
  TLS-intercepting proxy needs its root certificate supplied by hand. Neither
  has been verified against a real deployment. See "Known unknowns" in
  [docs/first-run.md](docs/first-run.md).

`test/smoke.sh` builds a real Lima instance from a throwaway repository,
checks the mounts, the firewall and the non-root user, and destroys it again.
