# Review Notes

Findings raised by code review — including multi-agent review via this
tool itself (`pi`-backed harnesses like `kimi-coding`, `openai-codex`,
`opencode-go`) — that were considered and don't need to be raised again.
Two kinds of entry live here:

- **Accepted risk**: a real issue, deliberately left unaddressed. Not a
  TODO list — if the decision changes, remove the entry and fix it
  instead of leaving both.
- **Non-issue**: something that looks like a bug or gap on a quick read
  but isn't, for reasons a reviewer wouldn't have context for. Explains
  why it's fine so it stops getting re-flagged.

## No coverage floor / CI gate (accepted risk)

No `minimum_coverage` in `spec/spec_helper.rb`, and Codecov is configured
with `fail_ci_if_error: false` (`.github/workflows/test.yml:56`), so the
current 100% line coverage is protected only by reviewer discipline, not
CI enforcement.
