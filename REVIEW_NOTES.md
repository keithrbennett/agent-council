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

## Accepted risk: Codex agents keep Codex's whole toolset

pi and Claude Code agents get a fixed allowlist of read and shell tools,
but Codex agents keep all of Codex's built-in tools, `apply_patch` (file
editing) and the subagent tools (`spawn_agent` and others) included.
codex-cli 0.167.0 has no option that withholds them:
`--disable multi_agent`, `-c features.multi_agent=false`, and
`-c include_apply_patch_tool=false` each left them in the rendered
prompt (`codex debug prompt-input`). What Codex agents can write is
whatever the user's `sandbox_mode` allows, which agent-council doesn't
override, as an interactive session wouldn't (`read-only`, Codex's
default, allows nothing; `workspace-write` allows the analyzed
repository). The README's "Choosing a harness" and "Safety and privacy"
sections state it. If Codex gains a way to withhold tools, use it and
remove this entry.

## Accepted risk: --consolidate leaves out provider-less agents of c60b7f8 runs

c60b7f8 (unreleased) let a Claude Code entry omit `provider`, filling in
`anthropic`; now every entry must give one, with no defaults. For a run
made by that commit, `missing_agents` skips a config-copy agent without
a provider (`labelable_entry?`), so the consolidator isn't told about it
if it has no report, and `--consolidate` rejects such a consolidator.
Only the maintainer's own pre-release runs can have such entries, and
bringing back an `anthropic` fallback (or reading labels from
`run.json`) for them would reintroduce a default. Fix by adding
`provider: anthropic` to the run's config copy.
