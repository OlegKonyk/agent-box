# Heal attempt {ATTEMPT} of {MAX} for run {PARENT}

The previous run of the brief below ended `{STATE}` (exit {EXIT}, result
`{RESULT}`). Its branch is `{BRANCH}`; the work tree is exactly as it left it,
with whatever it committed already on that branch.

The tail of its console:

```
{TAIL}
```

Its last words, if any:

> {LAST_TEXT}

Do this, in order.

1. **Diagnose before changing anything.** Read `/work/.agent-box/last-run.txt`
   and `/work/.agent-box/learnings.md` if it exists. Re-run the step that
   failed and read the error yourself.
2. **If the cause is the environment** (a missing tool, a broken install, a
   refused or flaky download, a stale cache, a port held by a dead process),
   repair it, then record what you did in `/work/.agent-box/learnings.md` in
   the shape the conventions above give.
3. **If the cause is the brief or the application**, do not loop on it.
   Record it as a learning with `Cause: brief` or `Cause: application`. Then
   either complete the brief if that is still possible, or write the question
   to `/work/.agent-box/ask.md` and stop.
4. **Then continue the original brief** from where the previous run stopped.
   Do not redo work that is already committed on this branch.

The original brief follows.

---

{BRIEF}
