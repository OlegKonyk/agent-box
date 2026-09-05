# Decisions

Why this is built the way it is, and what was rejected. Each entry names the
thing it is protecting against, because a control whose threat is forgotten
gets removed by the next person who finds it inconvenient.

## The two directions of isolation

Everything below serves one of two goals, and it is worth being explicit about
which, because they pull in different directions:

- **Outward.** The agent must not see the host. Not other repositories, not
  the host's SSH keys, not browser profiles, not the corporate filesystem.
- **Inward.** A personal subscription token must not end up on a
  work-managed machine's disk, in its backups, or in its logs.

A control that only serves one of these is not enough on its own.

## Why a virtual machine, and why Lima

A container shares the host kernel and, on macOS, would run inside a Linux VM
anyway. A VM boundary is the one that is easy to reason about and easy to
explain to whoever has to approve this.

Lima specifically, over the alternatives:

- **Apple's Virtualization.framework** through `vmType: vz`, so there is no
  emulation layer on Apple Silicon and no third-party hypervisor kext.
- **Mounts are declared, not discovered.** The instance sees exactly the
  directories the template lists. Lima's own default template mounts the host
  home directory read-only; this template does not, which is the single most
  important line in it.
- **Instances are disposable and scripted.** `limactl delete` takes the disk
  image and everything in it, including the token.
- It is a single Homebrew formula with no daemon and no login.

Rejected: **Docker Desktop** (licensing on a managed Mac, shared kernel, and
the default bind-mount ergonomics encourage mounting too much). **UTM** (GUI
first, awkward to script). **A devcontainer** (the isolation is the container's,
which is the boundary being avoided). **A second physical machine** (correct,
and not available).

## Why one instance per repository

Lima fixes mounts at create time. That is a limitation turned into a feature:
the set of files a VM can reach is decided once, when the VM is made, and
cannot drift afterwards. There is no command that adds a directory to a running
box, so there is no command to reach for at 11pm when something is nearly
working.

The cost is a disk image per repository, which is why `agentbox destroy` is a
first-class command rather than a footnote.

## Why the mounts are template parameters

Lima expands `{{.Param.Key}}` in `mounts[].location` (a host template) and in
`mounts[].mountPoint` (a guest template). Verified against Lima 2.2.0's own
annotated reference config, which shipped at
`/opt/homebrew/share/lima/templates/default.yaml`:

> "location" can use these template variables: {{.Home}}, {{.Dir}}, {{.Name}},
> {{.UID}}, {{.User}}, {{.Param.Key}}, {{.GlobalTempDir}}, and {{.TempDir}}.

So `bin/agentbox` passes `--param repo=... --param box=...` and the template
needs no rewriting. The two alternatives the spec allowed were not needed:
a `--set` yq expression (harder to read, and Lima restricts some yq operators),
and generating a derived YAML per instance into a config directory (a second
copy of the template that can go stale against this one).

The `param:` defaults in the template are placeholders. They exist so that
`limactl validate lima/agent-box.yaml` resolves to real paths on a bare
checkout; `bin/agentbox` always overrides both.

## Why `CLAUDE_CONFIG_DIR` is set by the provisioner, not by `env:`

`env:` values are **not** template-expanded. The list of fields that are
expanded is explicit in Lima's source (`pkg/limayaml/defaults.go`,
`executeGuestTemplate` / `executeHostTemplate` call sites): `user.home`, the
`provision` script, content, path and owner fields, `probes`, the mount
locations and mount points, port-forward sockets, and `copyToHost`. `env` is
absent from that list.

That matters because the guest home is not `/home/<user>`. Lima's builtin
default is `/home/{{.User}}.guest`, with `/home/{{.User}}.linux` kept as an
accessible alias; `limactl template copy --fill` on this template resolves it to
`/home/<user>.guest`. A literal path in `env:` would therefore be wrong, and a
templated one would be written through verbatim as the string `{{.Home}}`.

So the template's `env:` carries only the two literals that need no expansion
(`DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`), and the provision script —
which *is* expanded, and receives `{{.User}}` and `{{.Home}}` as arguments —
appends `CLAUDE_CONFIG_DIR` to `/etc/environment` and writes
`/etc/profile.d/agent-box.sh`. Lima rewrites `/etc/environment` during boot,
before provisioning runs, so appending on every boot is both necessary and
safe.

## Why the firewall is in the guest

The rules could live on the host — a packet filter rule per VM interface, or a
proxy the guest is forced through. Both were rejected:

- Host-level packet filtering on a work-managed Mac means changing a
  configuration the employer owns. That is exactly the sort of change this
  project exists to avoid needing.
- A proxy has to terminate TLS to filter by hostname, which means minting a CA
  and trusting it in the guest — building the very interception this setup
  otherwise treats as a hazard.

Inside the guest, `iptables` plus an `ipset` of resolved addresses is small,
inspectable, and the same mechanism Anthropic ships in its own devcontainer.
`guest/init-firewall.sh` is derived from that reference script and says so.

The honest limitation: the agent runs as a user that can `sudo`, because Lima's
guest user has passwordless sudo and the provisioning depends on it. An agent
that decided to disable the firewall could. This is a guard rail against a
capable tool doing something careless, not a sandbox against a hostile one. The
VM boundary is what protects the host; the firewall protects against
exfiltration by accident.

Two smaller choices inside it:

- **Rebuild every 15 minutes.** Allowlist entries are names, the ipset holds
  addresses, and the CDNs behind `api.anthropic.com` rotate theirs. A stale set
  fails closed — the agent simply stops being able to reach the model — which
  is safe but confusing, so a timer refreshes it.
- **IPv6 is closed entirely.** No v6 allowlist is maintained, and leaving v6
  open would be a way around every v4 rule.
- **Policies are reset to ACCEPT immediately after the flush.** The reference
  script assumes it runs once, from a clean container. Here it also runs from
  the timer, when the policy is already DROP — and the rebuild itself needs DNS
  and `api.github.com`. Without the reset, every refresh after the first would
  fail.

## Why `allowlist.local`, `blocklist.txt` and `ca.pem` live outside this repo

They are the three files whose contents are specific to wherever this is being
used: which internal hosts the app under test needs, which terms must never
leave, and which corporate root signs intercepted TLS. Each is a small
description of an employer's environment.

They live in `~/.config/agent-box/` on the host, and the `guest/` subdirectory
of it — containing `allowlist.local` and `ca.pem`, and nothing else — is mounted
read-only into the guest at `/opt/agent-box-config`. It is a mount, not a copy,
and that distinction is the whole point.

**The split into a subdirectory is not tidiness.** `blocklist.txt` stays in the
parent, unmounted. It is the literal list of employer-identifying terms, so it
is the single file in this project that most needs to stay out of a VM which
talks to a model under a personal subscription. Mounting the whole config
directory would have put it at `/opt/agent-box-config/blocklist.txt`, readable
by an agent running with `--dangerously-skip-permissions`, one `cat` away from
the transcript — and repository content is untrusted input that could steer an
agent into reading it. Nothing in the guest needs it: the firewall reads only
`allowlist.local` and provisioning reads only `ca.pem`. `agentbox create`
refuses to start if it finds `blocklist.txt` inside the mounted subdirectory.

An earlier version copied them into this checkout's gitignored `.local/`
directory. That was wrong twice over. A `.gitignore` is one `git add -f`, one
`git clean -x` mishap, or one repository-wide scanner away from publishing an
internal hostname, and the rule is that employer-identifying strings never enter
a durable artifact at all — not that they enter one and are then excluded. It
also coupled every instance to one shared file: creating a VM for repository B
rewrote the allowlist that repository A's running VM would read at its next
refresh, and running the smoke test with a hermetic config directory deleted the
real one out from under every live instance.

A mount has none of those properties. `agentbox create` creates the directory if
it is missing, and it is allowed to be empty.

`host/preflight.sh` reports **paths only** for blocklist matches — never the
matching line and never the term. A finding report is something you might paste
into a ticket; it must not become the leak it was looking for.

## Why the token never touches the host

`agentbox token` reads it with `read -rs` from `/dev/tty` and pipes it straight
into `limactl shell`. It is never a command-line argument (argv is world-visible
in `ps`), never an environment variable, never a file on the host, and never
echoed. On the guest it lands at `~/.config/agent-box/token`, mode 600, on a
disk image that `agentbox destroy` deletes.

`guest/agent-run.sh` refuses to start if `ANTHROPIC_API_KEY` or
`ANTHROPIC_AUTH_TOKEN` is set, because either silently outranks the OAuth token
and would bill an API account instead of drawing on the subscription. A silent
wrong-account run is worse than a loud failure.

## Why the guest user is not root

Claude Code refuses `--dangerously-skip-permissions` when running as root. That
flag is the point of a headless run in a disposable VM: the isolation is the
VM, so per-action prompting buys nothing and prevents unattended work. So the
agent runs as Lima's ordinary guest user, and `agent-run.sh` asserts it.

## Why the agent never pushes

`agent-run.sh` creates a branch, runs the task, and stops. Pushing is a durable,
outward act; a human reviews the diff on the host and pushes it under their own
identity. `ssh.forwardAgent` is false in the template, so the VM has no
credential to push with even if the script were changed.

Run logs are excluded through `.git/info/exclude` rather than the work repo's
`.gitignore`, because the work repo belongs to someone else and its tracked
files should not acquire a line about this tool.

## Why `agentbox start` re-runs preflight

A repository is scanned before it is mounted, but a repository changes between
sessions. Re-scanning on every start costs seconds and catches the case where
something confidential arrived in the repo after the VM was created.

## Why the firewall rebuild never removes the live ruleset

The reference devcontainer script flushes every rule, sets the policies to
ACCEPT, rebuilds incrementally, and sets them to DROP at the very end. That is
fine for a container that runs it once at startup. It is not fine here, for two
reasons that only appear when the same script runs on a timer.

**Every error path in between leaves the machine wide open.** Eight things can
fail between the flush and the final DROP: the `api.github.com` fetch, the JSON
field check, `pipefail` on a CIDR grep that matches nothing, an unparseable
CIDR, a missing default gateway. Any one of them ends the script with no rules
and an ACCEPT policy. The unit goes to `failed`, nothing restores the deny, and
the next attempt is fifteen minutes away. A brief GitHub outage at one timer
tick would silently give the box full internet access.

**And the rebuild window itself is a hole.** Between the flush and the final
policy there are no rules at all, for as long as one HTTP fetch plus one DNS
lookup per allowlisted name takes. Four times an hour, forever, unlogged.

So the new state is built beside the old one and swapped in:

- addresses go into a second ipset, populated fully, then `ipset swap`ped with
  the live one — atomic from the kernel's point of view;
- rules are applied with a single `iptables-restore`, which replaces the filter
  table as one transaction.

The rebuild therefore runs *under* the standing deny. It needs only DNS to the
configured resolvers and the GitHub ranges, both of which the previous run's
ruleset already permits. The first run is the one exception: there is no
ruleset yet, so the machine is briefly open, which is why provisioning does all
its downloading before the firewall is ever started.

**On failing closed.** There is an `ERR` trap, but it does not slam the box down
to loopback unconditionally, and that is deliberate. Because nothing tears down
the live ruleset, an error normally leaves the previous deny ruleset intact —
already the safe outcome, and a recoverable one, since the next timer tick can
still reach DNS and GitHub to try again. A box cut down to loopback-only cannot
rebuild itself at all: the rebuild needs exactly the access that was just
removed, so it would stay off the network until someone restarted it. The hard
close is therefore reserved for the one case where it is the only safe option —
an error when there is no standing deny ruleset to fall back on.

**And the hard close keeps the operator's door open.** Closing to loopback only
would be a mistake of a different kind: Lima reaches the guest over TCP to port
22, so a lo-only ruleset drops both new `limactl shell` connections and any
session already open — including the one needed to run the recovery the script
prints. The realistic trigger is a transient `api.github.com` failure on first
boot, which is exactly when someone needs to get in and look. So the hard close
also accepts `ESTABLISHED,RELATED` in both directions and inbound TCP port 22
from the gateway. Egress stays shut, because no *new* outbound connection is
permitted; only replies on connections that already exist. The one thing that
survives it is a connection opened before the close, which on a first-boot
failure means nothing is running yet.

## Why DNS is restricted to the configured resolvers

`-A OUTPUT -p udp --dport 53 -j ACCEPT` with no destination is an open
exfiltration channel, and it bypasses everything else in the file. A query name
is data: a lookup of `<base64-of-the-token>.attacker.example` against any
resolver on the internet carries the payload out, and never touches an
allowlisted address, the ipset, or the REJECT rule.

So both DNS rules carry `-d`, restricted to the resolvers the guest actually
has. Ubuntu may point `/etc/resolv.conf` at systemd-resolved on `127.0.0.53`, in
which case the addresses that really leave the machine are the upstream servers
in `/run/systemd/resolve/resolv.conf`, so both files are read; if neither yields
a non-loopback address, the gateway is used, because that is where Lima's host
resolver lives.

The verification asserts this directly: `dig @9.9.9.9` must fail.

## Why there is no blanket accept toward the host subnet

An earlier version turned the gateway address into a `/24` and accepted all
traffic to and from it, on every port, in both directions. Under `vmType: vz`
that subnet is the host plus every other VM on the machine, so the agent could
reach any port the work Mac had bound on that interface, entirely outside the
allowlist.

The justification given was `limactl shell`, and it was wrong: that is an
inbound SSH connection, already covered by the ESTABLISHED rule and by a single
inbound accept for port 22 from the gateway address. Nothing outbound is needed
for it. Everything else the guest legitimately needs from the host is either an
already-established connection or carried over vsock.

`propagateProxyEnv` is set to `false` for a related reason. Lima otherwise
copies the host's `http_proxy`, `https_proxy` and `no_proxy` into the guest's
`/etc/environment`. On a managed Mac those routinely name internal hosts — the
exact strings this VM exists to keep away from a personal subscription — and
they would hand the agent a general-purpose egress relay the allowlist does not
govern. A proxy that is genuinely wanted goes in `allowlist.local` and `ca.pem`,
which makes it a decision someone made rather than one that happened.

## Why verification asserts the mechanism, not one symptom

"`curl https://example.com` did not connect" is a weak claim. It passes just as
happily when DNS is broken, when curl is missing, when the interface is down, or
when the ruleset was never applied at all. It is also blind to the two holes
above: `example.com` is neither a DNS destination nor on the host subnet, so a
firewall with wide-open port 53 and a wide-open host subnet still prints PASS.

So the checks now assert what is actually true of a working ruleset: that the
OUTPUT policy is DROP, that a rule references the allowlist ipset, that the
IPv6 OUTPUT policy is DROP, that a *literal* address outside the allowlist is
refused (which tests the REJECT rule rather than name resolution), and that DNS
to a foreign resolver fails. The name-based probes are kept on top of that, not
instead of it.

IPv6 is closed outright, and its failure is no longer swallowed. Every
`ip6tables` call used to end in `|| true`, so on a kernel without the
`ip6_tables` module all of them failed, the script logged "IPv6 egress closed",
and IPv6 was wide open with every check still green.

## The token's residual risk, stated plainly

The token never touches the host filesystem: `agentbox token` reads it with
`read -rs` from `/dev/tty` and pipes it into the guest, never as an argument
(argv is visible in `ps`), never in the environment, never echoed.

What is *not* true is that the token can never reach the host. Inside the VM,
the agent runs with `--dangerously-skip-permissions`, can read the token file,
and can write anywhere under `/work` — which is the work Mac's filesystem, and
its Time Machine backups. That needs no malice on anyone's part: repository
content is untrusted input to a model, and the model's own output used to be
written straight onto the host mount.

Two changes, and one honest limitation:

- The full JSON transcript now stays in the guest home, at `~/.agent-box/runs/`.
  Only a scrubbed summary — branch, starting ref, model, exit code, a count of
  changed files — crosses to `/work/.agent-box/last-run.txt`.
- After every run, the transcript, `git status`, and both diffs are checked for
  the first and last eight characters of the token. A hit prints a loud warning,
  exits 3, and tells the user to rotate.

The limitation: this is a backstop, not a boundary. It catches the accident and
the obvious case. It would not stop a determined agent that encoded the value
before writing it. The boundary that actually holds is the VM plus the egress
allowlist; this check is there because the cost of a leaked personal credential
on a work machine is high enough to be worth a cheap second look.

## What the guest can still see: names

Lima's host resolver answers the guest's DNS queries using the work Mac's own
resolver configuration. Two consequences follow, and both are accepted rather
than fixed.

The guest can **resolve** internal names, including split-horizon names that
only exist on the corporate network. It cannot connect to them — the allowlist
governs where packets may go, and an internal address is not on it — but
existence and address are learnable. In the other direction, each lookup reaches
the employer's resolver with the VM as its origin.

This is accepted because the alternative is worse for the actual use case:
turning off the host resolver and pinning a public one in `dns:` would break the
common case where the app under test is reachable only through the corporate
resolver, which is precisely what `allowlist.local` exists to support. The thing
that limits damage is the allowlist, not the resolver. If a deployment does not
need internal names at all, setting `hostResolver.enabled: false` with an
explicit public `dns:` closes this, at the cost of that capability.

## Why the guest has a git identity

Provisioning sets `user.name` to `agent-box` and `user.email` to
`agent-box@localhost`, system-wide. Without them, a brief that says "commit your
work" ends at `Please tell me who you are`, or the agent improvises a `git
config` of its own, which is worse. The identity is deliberately generic:
nothing identifying the host user belongs in a commit an agent made. `--system`
keeps it out of the work repository's own config.

`safe.directory` is set for `/work` for a mechanical reason: over virtiofs the
tree is owned by the host uid, and git otherwise refuses to operate in it.
