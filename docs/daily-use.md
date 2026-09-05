# Daily use

`docs/first-run.md` gets the box built once. This is what using it looks like
afterwards: the two ways to drive it, what of your own setup comes with you,
what deliberately does not, and the friction you should expect rather than
debug.

---

## The two modes

**Interactive.** A normal Claude Code session, inside the VM, at `/work`:

```
./bin/agentbox claude ~/dev/my-e2e-tests
```

Arguments after the repository go straight to the CLI, so
`agentbox claude ~/dev/my-e2e-tests --model opus` works, and so does
`agentbox claude ~/dev/my-e2e-tests -p 'what does this suite cover?'`.

This is the mode to reach for when you are exploring, when the shape of the
task is not yet a brief, or when you want to watch. What it does not give you
is the headless mode's bookkeeping: no branch is made for you, the transcript
is on your screen rather than sealed in the VM, and nothing is scrubbed. That
is the trade — see `docs/decisions.md`.

**Headless.** One task, from a written brief:

```
cp templates/brief.md briefs/my-task.md   # fill it in
./bin/agentbox run ~/dev/my-e2e-tests briefs/my-task.md --model sonnet
```

The run gets its own `agent/<slug>-<timestamp>` branch, keeps its JSON
transcript inside the VM, writes only a short scrubbed summary to the host, and
checks that summary and both diffs for fragments of your token before it
reports success. Use this for anything you intend to review as a diff.

`agentbox shell` is still there for looking around, and does not authenticate
anything: nothing exports the token into a plain shell.

## Host configuration layout

Everything site-specific lives here and nothing of it is ever committed:

```
~/.config/agent-box/
  blocklist.txt              read on the host only, NEVER mounted
  guest/                     mounted read-only at /opt/agent-box-config
    allowlist.local          extra egress domains, one per line
    ca.pem                   corporate TLS-intercept root, if any
    plugins.txt              marketplaces to register, plugins to install
    plugin-dir/<name>/       plugin roots loaded per session, not installed
    claude/                  files copied into the guest's config directory
      CLAUDE.md
      settings.json
      governor.json
      rules/*.md
```

The split between the parent directory and `guest/` is the important one:
`blocklist.txt` is the list of terms that must never leave, so it is the one
file an agent must not be able to read. `agentbox create` refuses to start if
it finds it inside `guest/`.

## What carries over, and what does not

Carried over, by name, on every launch:

| File | Effect in the guest |
|---|---|
| `claude/CLAUDE.md` | `$CLAUDE_CONFIG_DIR/CLAUDE.md` — your standing instructions |
| `claude/settings.json` | user settings for the guest CLI, **filtered** — see below |
| `claude/governor.json` | governor configuration, if you use that plugin |
| `claude/rules/*.md` | `$CLAUDE_CONFIG_DIR/rules/` |

`rules/` is the one directory the sync owns outright, so it is the one place a
deletion follows: remove a rule on the host and the next launch prunes it in
the guest, with a `pruned` line saying so. The rest is additive — a `CLAUDE.md`
deleted on the host stays in the guest until you delete it there or destroy the
VM.

Deliberately not carried over, and refused out loud if you leave one there:

- **`.credentials.json` and anything `*.token`.** The VM gets exactly one
  credential, typed in by `agentbox token`, and it lives at
  `~/.config/agent-box/token` inside the guest at mode 600.
- **`projects/`, `history*`, `todos/`.** Your conversation history from other
  machines and other work has no business inside a VM pointed at a work
  repository. This is the inward direction of the threat model.
- **`plugins/`.** Installed plugin state is machine-specific; the guest
  installs its own from `plugins.txt`.
- **`.claude.json`.** It is the file the guest maintains itself, and it holds
  per-project history.

The copy is an allowlist, not a mirror, for the reason `docs/decisions.md`
gives: a blind copy of a directory you edit by hand is one careless `cp` away
from carrying a personal credential into a VM that runs against work code.

### `settings.json` is filtered, not just allowlisted

Matching on the file's name is not enough for this one, because the Claude Code
settings format can carry a credential inside a file that is legitimately on
the list. `env` is merged into the CLI's own process environment, so
`"env": {"ANTHROPIC_API_KEY": "sk-ant-..."}` is a literal key. `apiKeyHelper`
is a shell command the CLI runs to mint one. `awsAuthRefresh` and
`awsCredentialExport` do the same for Bedrock. None of that is exotic misuse —
it is the ordinary content of the very file you would copy in to get your
settings.

So the object is parsed and filtered on the way in. Those four keys are
removed, as is any value anywhere in the document that starts with `sk-ant-`,
and each removal is named:

```
sync-claude-config: STRIPPED settings.json:env — credential-bearing settings never cross into the guest
```

The same check runs again where the token is exported, so a `settings.json`
edited inside the guest cannot reintroduce one either: `agentbox run`,
`agentbox claude` and `agentbox verify-auth` refuse to start and name the key.
Both halves matter, because a key delivered this way would arrive *after* the
`ANTHROPIC_API_KEY` shell-environment check has passed, and would quietly bill
an API account instead of drawing on the subscription.

Two keys go the other way. `enabledPlugins` and `extraKnownMarketplaces` are
where `claude plugin install` records what it did, so they belong to the
guest's own CLI: the host's values are dropped and the guest's are preserved.
Without that, every sync would disable the plugins the guest had just
installed, and the host's marketplace entry — which names a directory on your
Mac — would be carried into a VM where that path does not exist.

Anything else in the file is yours and is copied as written, so a `hooks` entry
or a `statusLine` command that names a host path will simply not work in there.

## Plugins

Two mechanisms, for two different situations.

**Installed, from a marketplace.** Write `~/.config/agent-box/guest/plugins.txt`:

```
# one directive per line, '#' starts a comment
marketplace konyklabs/claude-plugins
install governor@konyklabs-plugins
install py-testing@konyklabs-plugins
```

`marketplace` takes what `claude plugin marketplace add` takes: an
`owner/repo`, a URL, or a path. `install` takes `plugin@marketplace`.

The marketplace **name** is not the repository name — it comes from the
marketplace's own `.claude-plugin/marketplace.json`. `konyklabs/claude-plugins`
registers as `konyklabs-plugins`. If you are unsure, add the marketplace and
read the name back:

```
./bin/agentbox shell ~/dev/my-e2e-tests
claude plugin marketplace add <owner/repo>
claude plugin marketplace list
```

The file is applied during provisioning, on first boot, and on demand:

```
./bin/agentbox plugins ~/dev/my-e2e-tests            # install what is missing
./bin/agentbox plugins ~/dev/my-e2e-tests --update   # refresh and update
```

It is idempotent: an already-registered marketplace and an already-installed
plugin are reported and skipped.

**Loaded per session, from the host.** Anything under
`~/.config/agent-box/guest/plugin-dir/` that contains
`.claude-plugin/plugin.json` is passed to the CLI as `--plugin-dir` by
`agentbox claude`, `agentbox run` and `agentbox verify-auth`. Nothing is
installed and nothing is written: the plugin is active for that session only,
straight from the read-only mount. This is the right shape for a plugin you are
still writing on the host — edit it there, run the next session, see the
change.

### The trust gotcha

A repository's own `.claude/settings.json` — its `extraKnownMarketplaces` and
`enabledPlugins` in particular — is **inert** in a folder Claude Code has never
been told to trust, and `-p` has no way to ask. The VM therefore marks `/work`
trusted for you, in `$CLAUDE_CONFIG_DIR/.claude.json`, every time it launches
anything. There is one folder in this VM and the host scanned it with
`preflight` before the VM was allowed to mount it, so this is a considered
decision rather than a convenience — but it is worth knowing that it happened,
because it means a repository's own plugin declarations do take effect in
there.

## Keeping the CLI current

Background self-update is off in the guest (`DISABLE_AUTOUPDATER=1`), so a run
cannot have its binary replaced underneath it. Update deliberately:

```
./bin/agentbox update ~/dev/my-e2e-tests
```

It prints the version before and after. Updates come from
`downloads.claude.ai`, which is on the base allowlist.

## The governor, in here

If you use the governor plugin, the guest is a good place for it: the workers
it pins to cheap models are the ones doing the bulk of the work, and the budget
it enforces is the same subscription your personal machine draws on. Two things
to know. Its configuration comes from `claude/governor.json` through the
carry-over above. Its state — the ledger, the spend so far — lives in the guest
under `~/.cache/governor` and **dies with the VM**, so a destroyed box takes
its own accounting with it.

## The friction, listed rather than debugged

None of these is broken. They are the shape of the thing.

- **One VM per repository.** Lima fixes mounts at create time, which is what
  makes "can it see X" answerable once instead of continuously. A second
  repository means a second `agentbox create`, and a second few minutes.
- **The app under test needs an allowlist entry.** So does anything a browser
  test talks to: a Playwright download host, a staging API, an internal package
  mirror. They go in `guest/allowlist.local`, one name per line. The symptom of
  a missing one is a connection refused inside the guest while
  `agentbox firewall-check` still passes.
- **A first boot that cannot reach GitHub installs no plugins.** A host simply
  off the allowlist fails fast, because the ruleset ends in REJECT. The slow
  cases are the other ones: GitHub accepting a connection and then not
  answering, or the hard-closed state a failed firewall init leaves behind.
  Every plugin CLI call is bounded at 120 seconds, so the boot finishes either
  way; `install-plugins` then exits 5 saying the marketplace was unreachable,
  and `agentbox firewall-check` is the next thing to run. The VM is fine, it
  just has no plugins yet.
- **Nothing pushes from the guest.** There is no git credential in there, and
  that is deliberate: you review the branch on the host and push it under your
  own identity.
- **The quota is shared with your personal machine.** The token draws on the
  same five-hour and weekly limits. A long unattended run in the VM is a run
  you cannot do at home that evening. `agentbox run` defaults to `sonnet` for
  that reason.
- **The interactive session is not scrubbed.** `agentbox run` checks its output
  for token fragments; `agentbox claude` hands you the terminal and cannot.
- **First boot is slow, later boots are not.** The Ubuntu image is cached under
  `~/Library/Caches/lima/download` and shared across instances.
