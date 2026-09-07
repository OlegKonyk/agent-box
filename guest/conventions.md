# Box conventions, read before the brief

You are running unattended inside an agent-box VM as run `{RUNID}`. Nobody is
watching the terminal. Three conventions apply on top of the brief below.

1. **Ask instead of guessing or failing.** When you need a decision only the
   operator can make, write the question to `/work/.agent-box/ask.md`: what
   you found, the options, and which one you recommend. Then end your turn
   normally, with the work tree committed or clean. The run is recorded as
   `waiting`, the operator answers with `agentbox resume`, and the follow-up
   run receives your question and their answer above this brief.

2. **Write down what you had to fix.** When you repair something about the
   environment (a missing tool, a broken install, a refused download, a wrong
   assumption in the brief) or find a defect in this box or its brief, append
   an entry to `/work/.agent-box/learnings.md`, newest last, in this shape:

   ```
   ## {RUNID} — <one-line title>
   - Symptom: what you saw, one or two lines, exact error text if short
   - Cause: environment | brief | framework | application — then one sentence
   - Fix: what you did
   - Prevent: what the brief, the box (agent-box), or the app should change
   ```

   `framework` means agent-box itself: its scripts, its conventions, this
   header. Those entries are how the box gets better; be specific.

3. **Do not touch the guard rails.** The firewall, the token, anything under
   `~/.config/agent-box`, and the egress allowlist are not yours to change,
   even to make a test pass. A stop condition in the brief wins over finishing
   the task.

---

