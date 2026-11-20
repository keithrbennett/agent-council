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

pi and Claude Code agents get an allowlist of built-in read and shell
tools (plus MCP tools: for pi, the tools that reach them; for Claude
Code, those permission rules allow), and OpenCode agents have their
file-editing tools withheld by a denied edit permission, but Codex
agents keep all
of Codex's built-in tools, `apply_patch` (file editing) and the subagent
tools (`spawn_agent` and others) included.
codex-cli 0.167.0 has no option that withholds them:
`--disable multi_agent`, `-c features.multi_agent=false`, and
`-c include_apply_patch_tool=false` each left them in the rendered
prompt (`codex debug prompt-input`). The subagent tools don't work,
though: under `--ephemeral`, which agent-council passes, `spawn_agent`
fails ("collab spawn failed ... no rollout found for thread id"), so a
Codex agent can't fan out, and its usage misses no subagent's (a
subagent's tokens aren't in its parent's `turn.completed`, so if
spawning ever works under `--ephemeral`, usage will undercount). What
Codex agents can write is
whatever the user's `sandbox_mode` allows, which agent-council doesn't
override, as an interactive session wouldn't (`read-only`, Codex's
default, allows nothing; `workspace-write` allows the analyzed
repository). The README's "Choosing a harness" and "Safety and privacy"
sections state it. If Codex gains a way to withhold tools, use it and
remove this entry.

## Accepted risk: agents get the user's MCP servers

Every harness loads the MCP servers it would load interactively, so an
agent can reach a server that writes (posts, comments, changes tickets
or records), Codex's apps connectors (GitHub and others) included:
agent-council no longer passes `--disable apps`. For pi agents only the scaffolding's rule against acting
outside the machine holds them back, and likewise for OpenCode agents,
whose MCP tools need no permission by default; Claude Code and Codex agents run
an MCP tool only if the user's settings or config (or, for Claude
Code, the analyzed project's settings) already allow it.
Withholding MCP made agents worse at the user's own work and, for
Codex, failed every agent when a plugin's server was listed (DESIGN.md
§11). Every pi agent also gets `codemode`, and with it pi's `models`
API, which can send what a script passes it to other models at the
user's expense. The README's Safety section states these risks and
where to turn each kind of server off.

## Accepted risk: OpenCode's edit denial is a default, not a guarantee

OpenCode agents run with `permission.edit: deny` (globally and for
`build`), which withholds the file-editing tools, but the user's or the
analyzed project's OpenCode config can allow editing again, for `build`
or for a subagent it defines, and `bash` can write files regardless.
agent-council doesn't try to close every way a config can override the
denial, which would mean tracking how OpenCode resolves permissions; it
is the same position as Codex, whose editing tool can't be withheld at
all. The project's config, `AGENTS.md`, and plugins apply with no trust
step, as Claude Code's project settings do. The README states this.

## Accepted risk: OpenCode agents' subagent usage and Ctrl-C

- A subagent's usage isn't in its parent's event stream, so an agent
  that starts subagents under-reports usage.
- On SIGTERM, `opencode` doesn't stop the commands it started, so
  after Ctrl-C those may keep running (DESIGN.md §7).

## Non-issue: OpenCode replaces a user's OPENCODE_CONFIG_CONTENT

The harness sets `OPENCODE_CONFIG_CONTENT` for its own settings rather
than merging an inherited value, as the Codex harness's
`developer_instructions` replaces the user's. A user can put the same
settings in an OpenCode config file, which is merged.

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
