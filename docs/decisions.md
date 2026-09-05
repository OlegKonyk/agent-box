# Decisions

Why this is built the way it is, and what was rejected. Each entry names the
thing it is protecting against, because a control whose threat is forgotten
gets removed by the next person who finds it inconvenient.

## Why the premise is an unattended agent, not a particular user

The isolation this project builds — one mounted repository, one token,
default-deny egress, no push — was worked out against a single scenario:
running an agent against a repository under a personal subscription. Nothing
in the actual design depends on who owns the machine or why the token is
personal, though. It depends on one thing: an agent is being allowed to run
without someone watching every action it takes, which is what turns an
ordinary mistake or a prompt injection into something expensive rather than
merely embarrassing.

So the premise is stated as the general case rather than the scenario it was
first built for. Whoever is running this — against their own project, a
client's repository, or code someone else owns — needs the same two
boundaries: the agent must not reach anything beyond the one thing it was
given, and whatever token it authenticates with must not be visible to what it
writes. Tying the tool to one relationship between operator and code owner
would have meant re-deriving the same guarantees for every other one; stating
the premise as "an unattended agent" instead means the isolation it earns does
not depend on the reason you needed it.

## The two directions of isolation

Everything below serves one of two goals, and it is worth being explicit about
which, because they pull in different directions:

- **Outward.** The agent must not see the host. Not other repositories, not
  the host's SSH keys, not browser profiles, not the rest of its filesystem.
- **Inward.** A subscription token must not end up on the host's disk, in its
  backups, or in its logs.

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

- Host-level packet filtering means changing a system-level configuration on
  the host itself, which may not even be yours to change. That is exactly the
  sort of change this project exists to avoid needing.
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
description of the environment it runs in.

They live in `~/.config/agent-box/` on the host, and the `guest/` subdirectory
of it — containing `allowlist.local` and `ca.pem`, and nothing else — is mounted
read-only into the guest at `/opt/agent-box-config`. It is a mount, not a copy,
and that distinction is the whole point.

**The split into a subdirectory is not tidiness.** `blocklist.txt` stays in the
parent, unmounted. It is the literal list of terms that must never leave, so it
is the single file in this project that most needs to stay out of a VM which
talks to a model under your subscription. Mounting the whole config
directory would have put it at `/opt/agent-box-config/blocklist.txt`, readable
by an agent running with `--dangerously-skip-permissions`, one `cat` away from
the transcript — and repository content is untrusted input that could steer an
agent into reading it. Nothing in the guest needs it: the firewall reads only
`allowlist.local` and provisioning reads only `ca.pem`. `agentbox create`
refuses to start if it finds `blocklist.txt` inside the mounted subdirectory.

An earlier version copied them into this checkout's gitignored `.local/`
directory. That was wrong twice over. A `.gitignore` is one `git add -f`, one
`git clean -x` mishap, or one repository-wide scanner away from publishing an
internal hostname, and the rule is that blocklisted strings never enter
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
- rules are applied with a single `iptables-restore --noflush`, which replaces
  the contents of the three chains agent-box owns as one transaction and leaves
  every other chain in the table alone. The original version omitted
  `--noflush` and replaced the whole filter table instead, which was equivalent
  until Docker arrived and then was not; see "Why the firewall owns three
  chains rather than the whole table" below.

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
reach any port the host had bound on that interface, entirely outside the
allowlist.

The justification given was `limactl shell`, and it was wrong: that is an
inbound SSH connection, already covered by the ESTABLISHED rule and by a single
inbound accept for port 22 from the gateway address. Nothing outbound is needed
for it. Everything else the guest legitimately needs from the host is either an
already-established connection or carried over vsock.

`propagateProxyEnv` is set to `false` for a related reason. Lima otherwise
copies the host's `http_proxy`, `https_proxy` and `no_proxy` into the guest's
`/etc/environment`. On a managed host those routinely name internal hosts —
exactly the strings this VM exists to keep away from a model — and
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
and can write anywhere under `/work` — which is the host's filesystem, and
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
allowlist; this check is there because the cost of a leaked subscription
credential on the host is high enough to be worth a cheap second look.

## What the guest can still see: names

Lima's host resolver answers the guest's DNS queries using the host's own
resolver configuration. Two consequences follow, and both are accepted rather
than fixed.

The guest can **resolve** internal names, including split-horizon names that
only exist on a private network. It cannot connect to them — the allowlist
governs where packets may go, and an internal address is not on it — but
existence and address are learnable. In the other direction, each lookup reaches
the host's resolver with the VM as its origin.

This is accepted because the alternative is worse for the actual use case:
turning off the host resolver and pinning a public one in `dns:` would break the
common case where the app under test is reachable only through a private
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

## Why plugins are installed inside the guest, and why the config sync is an allowlist

Two related choices, one about where plugins come from and one about what may
follow you in from the host.

**Plugins install from a public marketplace, inside the VM.** The obvious
alternative was to mount the host's `~/.claude/plugins` read-only and let the
guest use it directly. Rejected, for three reasons. It carries installed state
that is specific to another machine — cache layouts, versions, a marketplace
registered from a local checkout path that does not exist in the guest — so it
is not even portable. It widens the read-only mount from a handful of files the
user wrote to a directory the CLI manages on its own, which makes "what can the
agent see" a question about someone else's implementation detail. And it hides
provenance: a plugin that arrives by mount has no version and no source, where
one installed from `konyklabs/claude-plugins` has both, in a file that can be
read back with `claude plugin list`.

The install runs after the firewall comes up, deliberately. It pulls from
GitHub, which the allowlist permits through the ranges fetched from
`api.github.com/meta`, so every first boot is a live test of that rule. When
the GitHub range rule breaks, it says so during provisioning rather than the
next time someone needs a package.

The marketplace is public, which is the part that makes this work without a
credential: nothing about registering `konyklabs/claude-plugins` needs an
account. `plugins.txt` is applied during provisioning, before the token has
been typed in, and again on demand through `agentbox plugins`.

A plugin still being written on the host does not want any of that. For those
there is `--plugin-dir`, which loads one plugin root for one session, installs
nothing and writes nothing: the roots live under
`~/.config/agent-box/guest/plugin-dir/`, arrive through the same read-only
mount as the allowlist, and are passed to every session the box starts. Edit on
the host, run again, see the change.

**The config sync copies an allowlist of names, never a directory.** The
source is a subdirectory of a mount the user edits by hand, and the obvious
implementation — copy `claude/` into `$CLAUDE_CONFIG_DIR` — is one careless
`cp` away from carrying `.credentials.json` from the host into a VM pointed at
a repository that is not the host's own. That is the inward direction of the
threat model, the one that is easy to forget because nothing visibly breaks
when it fails.

So the names that may cross are written down — `CLAUDE.md`, `settings.json`,
`governor.json`, `rules/*.md` — and everything else stays behind. Credential
and history-shaped names are not merely skipped, they are refused out loud:
a silent skip and a successful copy look identical in a log, and the one case
where the operator must not be left guessing is the one where a credential was
in the directory.

Trust is marked in the same script, for a mechanical reason. Claude Code will
not act in a folder it has not been told to trust, a repository's own
`.claude/settings.json` is inert until it has been, and `-p` cannot ask. There
is exactly one folder in this VM and `host/preflight.sh` scanned it on the host
before the VM was allowed to mount it, so the decision is made here, visibly,
rather than by a flag buried in a launch command.

## Why there is an interactive `agentbox claude`, given `agentbox run`

`agentbox run` is the mode with the safety rails: a branch per run, the JSON
transcript sealed inside the VM, a scrubbed summary as the only thing written
to the host, and a check of that summary and both diffs for token fragments
before it will report success. Everything about it assumes the output is
untrusted and the host's disk is precious.

`agentbox claude` has none of that, on purpose. It hands the terminal to the
CLI, which is what makes an interactive session useful and also what makes it
unscrubbable: there is no boundary to filter at when the model's output is
being drawn on the operator's screen in real time. The choice was between
having no interactive mode at all — which sends people to `agentbox shell`
followed by a `claude` that cannot authenticate, or worse, to exporting the
token by hand — and having one that is honest about what it does not do.

What it does keep is every precondition `agent-run` insists on, from the same
`guest/lib.sh`: not root, a 0600 token file, no `ANTHROPIC_API_KEY` quietly
outranking the subscription, the firewall active. Those live in one file rather
than three copies precisely because three copies is how one of them ends up
being the lenient one.

## Why background self-update is off in the guest

`DISABLE_AUTOUPDATER=1` is set both in the Lima template's `env:` block, so it
holds from the first boot, and by the provisioner, so it survives Lima
rewriting `/etc/environment`.

An automatic update is a new binary arriving over the network in the middle of
a run, changing the thing being tested while it is being tested. That is
unwelcome in any VM whose whole purpose is a reproducible box. It is worse
here, because the failure mode of a *blocked* update is not an error: it is a
slow start, or a hang, with nothing pointing at the network. `agentbox update`
does it deliberately and prints the version either side, which turns an
invisible background action into a visible one with evidence.

## Why settings.json is parsed rather than trusted, and where that is enforced

The carry-over allowlist matches file names. `settings.json` is on it, because
it is the file that makes the guest CLI behave the way its owner expects. It is
also a file that can hold a credential, which means a name-based allowlist
alone does not deliver what the entry above promises.

Three keys, all ordinary content of that format:

- `env` is merged into the CLI's own process environment, so
  `"env": {"ANTHROPIC_API_KEY": "..."}` is a literal key.
- `apiKeyHelper` is a shell command the CLI runs to mint one.
- `awsAuthRefresh` and `awsCredentialExport` do the same for Bedrock.

The `env` case is the sharp one, because of *when* it takes effect.
`abx_assert_environment` refuses to run when `ANTHROPIC_API_KEY` is set in the
shell environment, and says why: an API key silently outranks the OAuth token
and bills an API account instead of drawing on the subscription. A key arriving
through `settings.json` is injected by the CLI *after* that check has passed.
The refusal is intact and the thing it refuses walks in behind it.

So the file is parsed, not copied: those keys are removed, along with any value
anywhere in the document that starts with `sk-ant-`, and each removal is named
in the log the way a refusal is. The host's own file is never touched.

The same check then runs again in `abx_assert_environment`, against the
installed copy, and refuses to launch. Two places, deliberately: the filter
covers the file that crosses the mount, and the assertion covers a
`settings.json` written or edited inside the guest, which the filter never
sees. A guarantee enforced only at the point of copying is a guarantee about
copying, not about running.

## Why the trust merge locks, and never renames the file aside

`sync-claude-config.sh` runs before every launch and does a read-modify-write
of `.claude.json`, a file Claude Code also writes. An earlier version answered
a parse failure by renaming the file aside and starting fresh. That is the
worst available response to the most likely cause.

The most likely cause is not corruption. It is catching the file mid-write —
an interactive session in one terminal, `agentbox run` in another. Renaming
then takes a live session's config, with every other project's trust decision
and history in it, and puts it in a `.corrupt-<epoch>` file nobody will ever
look at; the running CLI writes its own state over the two-key replacement, and
the loss is permanent and silent.

Now: an flock on a sibling lockfile serialises this script against itself, and
a parse failure means re-read once after a short pause and then, if it still
does not parse, say so and exit non-zero **without touching the file**. The
caller already treats a failed sync as non-fatal, so the cost is one launch
running with the trust flag unset — recoverable on the next command. Displacing
a live config is not recoverable at all.

The lock cannot serialise this script against the CLI, which is why the second
half matters more than the first.

## Why settings.json is merged, not copied: the file has two owners

Carrying `settings.json` across looks like copying one file. It is not, because
two parties write to it.

The operator writes their preferences. The CLI writes `enabledPlugins` and
`extraKnownMarketplaces`, which is where `claude plugin install` records what
it installed. A wholesale copy makes the host the only author and destroys the
CLI's half — so the guest installs its plugins during provisioning, the next
launch syncs the config over the top, and every one of them is quietly
disabled. `claude plugin list` still reports them as installed. The smoke test
caught exactly this, which is why it now asserts the plugin is *enabled* rather
than merely present.

The same two keys are wrong in the other direction as well. The host's
`extraKnownMarketplaces` names a directory on the host — a path that does not
exist in the guest, and one there is no reason to write into a VM. That makes
these keys machine-specific state, the same category as the `plugins/`
directory that was already on the refused list.

So they are guest-owned: dropped from the incoming file, preserved from the
guest's own. Everything else in the file is the operator's and crosses as
written, which does mean a `hooks` or `statusLine` entry naming a host path
will not work in the guest. That is left as the operator's problem rather than
guessed at, because rewriting someone's commands is a worse failure than
letting one of them not run.

## Why the Docker profile is opt-in per instance

Every instance could have Docker, Node 22 and Playwright's system libraries.
None of them is dangerous on its own, and the firewall now holds containers to
the same allowlist as the guest. The reason not to is that all three are large,
slow and attack surface: the Docker packages, containerd and the buildx and
compose plugins are a few hundred megabytes, `playwright install-deps` pulls in
most of a desktop's graphics and font stack, and both need the disk to be twice
the size before a single image is pulled. A box that exists to run one agent
against one repository of TypeScript should not carry a container runtime it
will never start.

So the profile is three flags on `create`, and it is fixed for the life of the
instance — the same reasoning as the mounts. "Can this VM run containers" is
answerable once, from the command that made it, rather than being a thing that
might have been turned on at some point. Sizing is the one exception:
`agentbox resize` exists because outgrowing a 60GiB disk is an ordinary event
and rebuilding the VM to fix it is not a reasonable answer.

## Why rootful Docker, not the rootless engine

Lima ships a `docker` template that installs the rootless engine, and rootless
is the better default nearly everywhere: the daemon runs as the user, a
container escape lands in an unprivileged account, and nothing needs
`CAP_NET_ADMIN`.

It cannot be used here, for a specific and checkable reason. Rootless Docker
does its networking inside a user network namespace with slirp4netns or
pasta, and populates **none** of the `DOCKER*` chains in the host namespace.
There is no `DOCKER-USER` to hook into, no `FORWARD` traffic to filter — the
container's packets appear on the guest's uplink as if the daemon's own process
had sent them, and the only thing standing between a container and the internet
would be the guest's `OUTPUT` chain, which is the daemon's, not the container's.
The egress allowlist would still hold at the outer boundary, but "which
container reached what" would be unanswerable and the per-container rules the
`AGENTBOX-FWD` chain expresses would have nowhere to live.

The rootful engine, from Docker's own apt repository, creates
`DOCKER-USER` and `FORWARD` jumps to it before anything else. That chain is
Docker's documented place for exactly this, and since Engine 28.0.1 it has no
implicit `RETURN`, so a rule placed there governs container traffic properly.

The cost is stated rather than hidden: the guest user is in the `docker` group,
which is root-equivalent on that guest. It changes nothing about the threat
model, because the guest user already has passwordless sudo — see the first
entry under "Limits and known weaknesses" in the README. The VM boundary is
what protects the host; the firewall is a guard rail against carelessness.

The repository key is pinned. Docker's current install pages give the key's URL
and no fingerprint beside it, so provisioning fetches the key once, reads its
fingerprint with `gpg --show-keys`, and refuses to point apt at the repository
unless it is `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` — the
fingerprint of "Docker Release (CE deb) <docker@docker.com>", rsa4096, created
2017-02-22, read back from that URL in a guest on 2026-09-05. That is a pin
against a future substitution, not proof of provenance today: the first fetch
was trusted, and it is the pin that makes the second and every later one
checkable. Saying so is the point.

## Why the firewall owns three chains rather than the whole table

The old ruleset was applied with `iptables-restore` and no `--noflush`, which
replaces the entire filter table in one transaction. That was a virtue while
agent-box was the only thing writing rules. With Docker installed it is a
defect, and a quiet one.

Docker creates six chains — `DOCKER`, `DOCKER-USER`, `DOCKER-FORWARD`,
`DOCKER-CT`, `DOCKER-BRIDGE`, `DOCKER-INTERNAL` — and **does not put them back
if something else removes them**. Only a daemon restart does. So the
whole-table restore would have cut every container off the network on the first
15-minute timer tick after the daemon started, and left it that way: the
symptom is a compose stack that worked for twelve minutes and then did not,
with nothing in any log to say why.

The fix is to own three chains and nothing else:

| chain | reached from | holds |
|---|---|---|
| `AGENTBOX-IN` | `INPUT` rule 1 | loopback, established, port 22 from the gateway |
| `AGENTBOX-OUT` | `OUTPUT` rule 1 | the guest's own egress allowlist |
| `AGENTBOX-FWD` | `DOCKER-USER` rule 1 | the same allowlist, for container traffic |

and to declare only those three, plus the three policies, in a restore file
applied with `--noflush`. Two behaviours make that work, and both were checked
in a guest rather than taken from documentation:

- declaring a **user** chain (`:AGENTBOX-OUT - [0:0]`) under `--noflush`
  replaces its contents outright, so a rebuild is still one atomic swap and
  never duplicates a rule;
- declaring a **builtin** chain (`:INPUT DROP [0:0]`) under `--noflush` sets its
  policy and leaves its rules alone.

That asymmetry is the whole reason the accept rules moved out of `INPUT` and
`OUTPUT` into chains of our own. Rules left directly in a builtin chain could
not be rebuilt in place: appending them again each run would duplicate them,
and flushing the builtin first would remove `FORWARD`'s jumps to Docker's
chains.

The jumps themselves are placed with `-C || -I`, inserted before any duplicate
is deleted, so there is no instant in which `DOCKER-USER` does not reach our
rules. `AGENTBOX-FWD` begins with `! -o <uplink> -j RETURN`: traffic that is not
leaving by the default route's interface is container-to-container or a
published port arriving from the other side, neither of which is egress, and
`DOCKER-FORWARD` is the chain that should decide it.

`iptables -F` with no argument has the same defect as the whole-table restore
and appears in two more places — the provisioner opening the network for a
download, and the hard-close path. Both now flush the three builtin chains and
our own three, never the table.

## Why docker.service gets a drop-in, and why the socket is owned by name

Two lines in `/etc/systemd/system/docker.service.d/agent-box-firewall.conf`,
for two different failures.

`After=agent-box-firewall.service` orders the daemon behind the firewall at
boot, so `AGENTBOX-FWD` exists before `DOCKER-USER` does.

`ExecStartPost=…/init-firewall.sh --docker-hook` closes the window a restart
would otherwise open. A daemon restart recreates whatever of its chains are
missing; if the jump were left to the 15-minute timer, a `systemctl restart
docker` at 12:01 would leave containers reaching anything they liked until
12:15. As an `ExecStartPost` the hook runs as part of starting the daemon, so
`systemctl restart docker` does not return until the jump is back. The hook
does one thing and does not rebuild anything, because a rebuild needs DNS and
`api.github.com` and must never be on the critical path of starting a daemon.

A second drop-in, on `docker.socket`, names the guest user as the socket's
owner. `usermod -aG docker` is also done and is not enough: supplementary
groups are fixed when an SSH connection authenticates, and Lima multiplexes
every `limactl shell` over one long-lived connection opened before provisioning
ran. Verified rather than assumed — after `usermod`, a fresh `limactl shell`
still reported the old group list and `docker info` said "permission denied".
The group would only take effect after a stop and start, which means the box
you just built to run Docker cannot run Docker. Lima's own docker template sets
`SocketUser` for the same reason.

## Why there is still one Lima template, and no generated file per instance

`--docker`, `--playwright` and `--rosetta` reach the guest as template
parameters, which Lima expands in the provision script. `--forward`, the
Rosetta setting and the sizing cannot work that way, and the reason is worth
recording because it looks like it should.

Lima parses the template as YAML **first** and expands `{{.Param.x}}`
afterwards, in a handful of string fields only. So `enabled: {{.Param.rosetta}}`
is a YAML parse error before any parameter exists, `enabled: "{{.Param.rosetta}}"`
parses but is never expanded and reaches the VM as that literal string, and
`- guestPort: "{{.Param.port}}"` is rejected outright because `guestPort` is an
integer. All three were tried against `limactl validate` rather than reasoned
about.

The obvious next step is a derived per-instance YAML written under
`~/.config/agent-box/instances/`, and it is not needed: `limactl create` takes
`--rosetta`, and `--set` with a yq expression, which together express both. So
`agentbox create` passes `--set '.cpus = N | .memory = "…" | .disk = "…"'`,
adds `--rosetta` when asked, and prepends port-forward entries with
`--set '.portForwards = [{"guestPort": N}] + .portForwards'`. Prepends, because
the template's two catch-all entries ignore every port and Lima takes the first
entry that matches.

The result keeps the property that mattered: **one template, in the repository,
readable as a file**. A generated per-instance YAML would have put the real
configuration of a running VM somewhere nobody reviews, and would have needed
its own regeneration story every time the template changed. `agentbox resize`
uses the same mechanism against an existing instance with `limactl edit --set`.

## What `--forward` gives up

Every other design decision here points one way: nothing the guest listens on
is reachable from the host. `--forward` is the exception, and it exists because
watching a browser test against a stack running in the VM is otherwise
impossible — you cannot look at `http://localhost:3000` if nothing is
forwarded.

It is a widening in the direction the rest of the file spends its effort
closing, so it is opt-in per port, per instance, fixed at create time, warned
about in one line at create, and recorded in the instance summary. What it
grants is narrow: a process on the Mac can connect to that one guest port at
`127.0.0.1`. It grants the guest nothing new in the other direction. The
alternative considered and rejected was forwarding on demand from a separate
subcommand, which would have made "what is exposed right now" a question with a
time-varying answer — the same thing the fixed-mounts rule exists to avoid.

## Why the allowlist resolves through two paths, and more than once

The allowlist is names; the ipset is addresses. Something has to turn one into
the other, and `dig` on its own turns out to be the wrong instrument.

**`dig` does not resolve the way anything else does.** It sends its query
straight to the nameserver in `/etc/resolv.conf` — on this guest, Lima's host
resolver on the gateway. Every other program goes through glibc to
systemd-resolved on `127.0.0.53`, which keeps its own cache and its own idea of
which address the name has. For a name with eight A records the two answers
overlap enough that nothing is noticed. For `cdn.playwright.dev` — an Azure
Front Door endpoint that answers with exactly **one** A record, on a near-zero
TTL — they disagreed outright, in the same second, in a guest:

```
$ dig +short A cdn.playwright.dev        # what the firewall pinned
150.171.109.113
$ getent ahostsv4 cdn.playwright.dev     # what curl would use
150.171.109.70
```

So the firewall allowlisted an address nothing was going to connect to, and
rejected the one everything did. The symptom is a host that is plainly on the
allowlist being refused, which is the most misleading failure this design can
produce: it looks like the allowlist file is wrong when it is right.

The fix is to resolve the way the applications resolve. `getent ahostsv4` goes
through the same NSS path curl, Node and apt do, and its result is unioned with
`dig`'s, which still contributes the fuller multi-address answers that `getent`
returns one line at a time. Measured in a guest after the change: five
consecutive requests to `cdn.playwright.dev` under the standing deny all
connected, all to `150.171.109.66`, the address both paths now agree on.

**And a pass count that defaults to one, having been three.** A CDN hands out
part of its pool per query, so a single lookup pins a single slice for fifteen
minutes. Several passes over the whole list, spaced past the TTL, collect more
of it. That was implemented, measured, and then turned down to one pass,
because the measurement said so:

| resolution passes | first boot of a plain instance |
|---|---|
| 1 | 50-59s, across four runs |
| 3 | 611s, past Lima's own start budget, so `agentbox create` failed |

The cost is not the DNS traffic. It is `getent`: it takes no timeout of its own
and NSS blocks while systemd-resolved is still coming up, which is exactly when
this script first runs. The lookup is now bounded with `timeout`, and the extra
passes — which on the case above changed nothing, because the two-path union
had already fixed it — sit behind `AGENT_BOX_RESOLVE_PASSES` for whoever meets
a CDN that needs the breadth and can afford the boot time.

**This is a mitigation, not a guarantee, and pretending otherwise would be the
real defect.** An address that enters a pool between rebuilds still fails.
Three things follow:

- A rejected connection to an allowlisted CDN is worth retrying before it is
  worth debugging. `agentbox firewall-check` forces a rebuild and refreshes the
  set.
- The smoke test's reachability checks retry up to six times each, the same
  shape a real downloader has. A name that is genuinely absent still fails all
  six, and the check that found this in the first place is the one that curls
  every newly allowlisted name from inside the guest *under the standing deny*
  — provisioning downloads with the firewall stopped, so nothing else would
  ever have noticed.
- Two alternatives were considered and not taken. Widening to the CDN's
  covering prefix (`150.171.108.0/22` for that Front Door pool) allowlists
  every other tenant on the same CDN. Keeping addresses with an `ipset`
  timeout instead of replacing them wholesale would accumulate a pool over
  hours, but it trades the atomic swap — the property that makes a rebuild safe
  under the standing deny — for an hour-long tail of addresses that are no
  longer the allowlisted host's.
