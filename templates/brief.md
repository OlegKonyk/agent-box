# Brief: <one-line title>

Copy this file, fill it in, and hand it to the VM:

    agentbox run <repo> briefs/my-task.md --model sonnet

The whole file is the prompt. Anything vague here becomes a guess in there.

## Task

What to do, in two or three sentences. State the outcome, not the steps —
the steps are the agent's job. If a specific approach is required, say so and
say why, because otherwise it will be treated as one option among several.

## Repo and files in scope

The mount is `/work`. Name the directories and files that may be changed.

- `src/...`
- `tests/...`

Everything not listed is out of bounds.

## Definition of done

Checkable statements, not aspirations. Someone reading the diff must be able
to decide yes or no on each line without asking a question.

- [ ] ...
- [ ] ...
- [ ] The commands under "Tests to run" all pass, with their output pasted.

## Tests to run

Exact commands, copy-pasteable, in the order they should run.

```
npm test
```

## Out of scope

The things that look adjacent and are not wanted. Being explicit here is
cheaper than reviewing a diff that wandered.

- Reformatting files the task does not touch.
- Dependency upgrades.
- Renaming anything.

## Stop conditions

When to stop and report rather than improvise.

- A test fails for a reason the brief does not cover.
- The change would need a file outside the scope above.
- The same failure recurs after two genuinely different fixes.
- Anything here turns out to be wrong or impossible.

## Notes

Nothing in this brief may name a customer, an employer system, or an internal
hostname. The repository is generic and this file travels with it.
