# Contributing

Issues are welcome, for bugs, unclear docs, or a limitation worth tracking.

For a pull request:

- Run `shellcheck` on every changed script and paste clean output.
- Run `test/smoke.sh` and paste its output.
- Add nothing site-specific to the repo — hostnames, terms, or credentials
  belong in `~/.config/agent-box/`, never in a tracked file.
