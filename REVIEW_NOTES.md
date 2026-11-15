# Review Notes

Findings raised by code review — including multi-agent review via this
tool itself (`pi` provider routes like `kimi-coding`, `openai-codex`,
`opencode-go`) — that were considered and don't need to be raised again.
Two kinds of entry live here:

- **Accepted risk**: a real issue, deliberately left unaddressed. Not a
  TODO list — if the decision changes, remove the entry and fix it
  instead of leaving both.
- **Non-issue**: something that looks like a bug or gap on a quick read
  but isn't, for reasons a reviewer wouldn't have context for. Explains
  why it's fine so it stops getting re-flagged.

## Accepted risk: the analyzed repository's Claude Code settings apply untrusted

`claude -p` shows no workspace-trust prompt, so the analyzed
repository's `.claude` settings apply to every Claude Code agent, even
in a repository never opened interactively. Their hooks, for one, run
commands as the user (checked with Claude Code 2.1.325); whether other
settings that run commands are also honored there is untested. This is deliberate: agents load `CLAUDE.md`,
settings, hooks, and plugins as an interactive session would, so they
see the project as its own developers do. The README's "Safety and
privacy" section states the risk and the opt-out,
`CLAUDE_CODE_SAFE_MODE=1`, which turns off customizations such as
hooks, plugins, and `CLAUDE.md` while permission rules still apply.
Leaving out project settings instead, with `--setting-sources` or
`--restricted` (which ignores user, project, and local settings files),
was not adopted: unlike safe mode, either would also drop the project's
own permission rules, and neither is tested.

## Non-issue: a harness without DEFAULT_PROVIDER would make validation raise

`entry_error` and `Harnesses.with_defaults` read each registered
harness's `DEFAULT_PROVIDER` without checking that it is defined. Every
harness must define it (`nil` when entries must give a provider): it is
part of the interface documented in `lib/agent_council/harnesses.rb`,
and `spec/agent_council/harnesses_spec.rb` fails for a harness that
lacks it, so a missing one is caught in CI, not by users.
