# Design

## 1. Goal

The long-term goal is to collect genuinely different viewpoints on the same question from multiple harness/model instances, and, because every instance gets the identical task, to compare those instances against each other on speed, token usage, cost, and quality.

This repository is the first step: it varies the models and, per agent, the harness, which is Pi (for any provider's models), Claude Code (for Anthropic's), or Codex (for OpenAI's). More harnesses may follow (§18).

It is packaged as a gem for easy installation, but it is intentionally not a general-purpose framework.

agent-council is a small Ruby CLI that runs the **same prompt** through several AI harness/provider/model combinations, under the Pi, Claude Code, or Codex coding-agent harness, and saves each final response to a deterministic Markdown file.

The objective is utility, not completeness. Given a config (§5), one command:

```bash
agent-council prompt.md
```

quickly gets independent reports from several models.

---

## 2. Why

Different models often produce materially different analyses of the same codebase or problem.

Typical prompts include:

- What is the best way to resolve this issue?
- Give me a comprehensive state-of-the-codebase analysis.
- Identify important codebase issues needing attention.
- What architectural or maintainability problems should we address?

We want each model to receive the same substantive prompt so that differences in results come from the models themselves.

agent-council does not rank or debate the responses; synthesis is limited to the optional consolidator (§12).

It simply obtains and preserves them.

---

## 3. Core Principle

Each ensemble member receives the same substantive prompt.

For example:

```text
                    prompt.md
                        |
          +-------------+-------------+
          |             |             |
          v             v             v
      Pi + Kimi      Pi + GLM     Claude Code
                                    + Opus
          |             |             |
          v             v             v
       report         report         report
```

---

## 4. Architecture

There are three harnesses, pi, Claude Code, and Codex, and the orchestration is harness-agnostic: it looks up each agent's harness module by its config entry's `harness` key (§5) in `AgentCouncil::Harnesses::BY_NAME` (`lib/agent_council/harnesses.rb`), so another harness is another such module, added there. Every config entry names its harness (§5); reports and `run.json` entries always record theirs, and one that gives none (hand-edited, or older than 0.1.0, when every agent ran under pi) is read as pi's. Each module is a plain namespace with the same functions (`NAME`, `argv`, `usage`, `error_message`, `exit_detail`, `warnings`, `final_response`, `assistant_messages`); `NAME` is both the config value and the executable that `argv` runs, which the startup check looks for on `PATH`, and goes into filenames unsanitized, so it must be filename-safe. Claude Code and Codex take no provider argument, so their entries' provider only labels the agent. The scaffolding text (§10) is shared.

**Labels.** The short labels (`#1 provider / model`) don't show the harness. They appear in progress lines, result tables, the consolidation prompt, and a consolidated report's `### Sources` table and `sources` front matter. The startup agent list, each report's byline table, and the findings file's legend (`#1 pi / provider / model`) do show it. Short labels don't need the harness to stay unique: the only ones used as lookup keys are the analysts', which match reports to their `run.json` entries and to the configured agents, and each carries its agent number. Nor does the consolidator need it in the labels, since each report it reads states its harness in its byline (§12). So they stay as they are, and a mixed run's output reads the same as before.

The Ruby program owns orchestration and invokes the harness once per configured agent.

```text
Ruby CLI
   |
   +-- Pi + model A
   +-- Pi + model B
   +-- Claude Code + model C
   +-- Codex + model D
```

---

## 5. Configuration

A simple YAML file defines the ensemble.

Example:

```yaml
agents:
  - harness: pi
    provider: anthropic
    model: MODEL_ID_HERE

  - harness: pi
    provider: openai
    model: MODEL_ID_HERE

  - harness: pi
    provider: opencode-go
    model: MODEL_ID_HERE

  - harness: pi
    provider: zai
    model: MODEL_ID_HERE

  - harness: claude        # Claude Code; the provider only labels the agent
    provider: anthropic
    model: MODEL_ID_HERE

consolidator:              # optional; synthesizes the agents' reports (§12)
  harness: pi
  provider: anthropic
  model: MODEL_ID_HERE
```

Every entry gives `harness`, `provider`, and `model`, each a nonblank string; there are no defaults, and no `defaults:` section supplying them (one was considered and rejected). A default harness or provider would go stale as harnesses change (pi is the right default only as long as it is), and a `defaults:` section's provider would apply across harnesses whose providers differ. `harness` is `pi`, `claude`, or `codex`; an unknown one is rejected at startup (with `--consolidate`, only the consolidator's, since no analysts run). A `claude` entry's provider is not passed to Claude Code (§4) and only labels the agent (e.g. `bedrock`, for a `claude` set up to use it); likewise a `codex` entry's, since Codex uses the `model_provider` its config names. A config error lists every bad entry, each named by its key (`'agents' entry #2`, `'consolidator'`) with every problem it has, so one edit fixes them all; when an entry gives no harness, a line saying what every entry needs follows, and, if no entry gives one (as in a 0.1.0 config, which ran everything under pi), a hint to add `harness: pi`. A run made by 0.1.0, when every entry ran under pi, has a config copy without `harness`; `--consolidate` rejects its consolidator like any other entry, with a hint to add `harness: pi`, while its reports and `run.json` are still read as pi's.

Exact provider and model identifiers must be verified against the installed harness: `pi --list-models` for pi, the names and aliases `claude --model` accepts for Claude Code, and the names `codex --model` accepts for Codex.

They belong in configuration because available models and names change frequently.

---

## 6. CLI

Command:

```bash
agent-council [-o DIR] PROMPT_FILE [CONFIG_FILE]
agent-council --consolidate RUN_DIR
```

The README's [Running](README.md#running) section and `agent-council -h`
document the arguments, options, and `AGENT_COUNCIL_OPTS`. The command:

1. reads the prompt;
2. reads the configuration;
3. launches all configured analysts;
4. saves each successful result as its agent finishes;
5. waits for all of them, then prints a concise success/failure summary;
6. runs the consolidator, if one is configured, over the saved reports.

`agent-council --consolidate RUN_DIR` runs only the
consolidation of a finished run, using the run dir's own prompt and
config copies, found through its reports' front matter (§12).

---

## 7. Parallel Execution

Agents run concurrently, one Ruby thread per agent, each driving one harness process.

`AgentCouncil::WorkerPool` (`lib/agent_council/worker_pool.rb`) also handles signals, keeping the main thread free to take them. The README's [Stopping a run](README.md#stopping-a-run) section describes what Ctrl-C and the other signals do; the reasons behind that behavior are:

- **Each agent leads its own process group**, so the terminal's signals reach only agent-council, which then stops the agents itself, in an orderly way, and Ctrl-Z suspends agent-council without suspending the agents under it.
- **Agents get SIGTERM and a shared grace period before being killed**, so the harness can stop the commands it started (pi, Claude Code, and Codex do; checked for Codex 0.167.0: a running `sleep` was gone after `codex` got SIGTERM; checked for Claude Code 2.1.325: a command its Bash tool was running, in the foreground or with `run_in_background`, ran in a process group of its own, which agent-council's SIGTERM to the agent's group doesn't reach, and ended when `claude` got SIGTERM); a second signal skips the wait for a user who doesn't want to.
- **agent-council then dies by the signal** rather than exiting normally, so a shell (e.g. one running it in a loop) sees it was killed and stops too. SIGQUIT exits 131 instead, since a core dump is no use here.
- **Extra SIGHUPs are ignored**, since a closing terminal can send them in pairs, and **signals agent-council was started ignoring stay ignored**, so `nohup` works.
- **SIGQUIT isn't trapped under JRuby**, where the JVM reserves it for thread dumps.

There is no job system, daemon, async framework, or workflow engine.

---

## 8. Prompt Identity

agent-council does not:

- assign different roles to the analysts;
- customize analytical instructions per model;
- ask models to identify themselves;
- add model-specific output instructions.

Execution metadata stays outside the substantive prompt: the scratch dir is referred to only as `$TMPDIR` in the system-prompt scaffolding, which is identical for every agent, and model identity is in the report's front matter.

---

## 9. Prompt Delivery

The prompt is piped to the harness on stdin, never interpolated into a command line, so it may be large and contain:

- Markdown;
- source code;
- quotes;
- shell characters;
- Unicode;
- long analytical instructions.

The harness is started with an argv array, not through a shell.

---

## 10. Repository and System Safety

Agents are analyzers, not modifiers.

The scaffolding appended to each agent's system prompt (`Harnesses.scaffold_text` in `lib/agent_council/harnesses/scaffold.rb`, shared by every harness) states the rules agents get, and the README's [How it works](README.md#how-it-works-and-what-the-agents-are-told) section summarizes them. They are instructions, not enforced restrictions: each harness's tool limit (pi's `--tools` allowlist, which activates only the built-in, extension, and custom tools it lists, and the MCP tools that `codemode`, `tool_search`, and `mcp__*` reach, §11; Claude Code's `--tools`; Codex has none, §11) is the only restriction agent-council enforces (Claude Code's own sandbox can also restrict Claude Code agents if Claude Code's settings enable it, and the analyzed repository's settings can enable or disable it; Codex's sandbox restricts Codex agents as the user's Codex config sets it; §11), and the shell tool remains a full shell running as the user (see the README's [Safety and privacy](README.md#safety-and-privacy)). A shell is kept because investigation (`git log`, dependency inspection, running a documented command) is much of what makes an analysis useful.

The rules follow from agents running concurrently in the user's own working tree:

- **No modifying project files, git state, software, or configuration, and no persistent services**, since the agents analyze the user's real repository and environment, not a copy. If testing a proposed change would need a modified file, the agent should describe the experiment instead (this follows from the rule; the scaffolding doesn't state it separately).
- **Each agent gets its own disposable scratch directory** (its `TMPDIR`, which the scaffolding names rather than giving a path: under Claude Code's sandbox the dir itself is read-only and `TMPDIR` is a writable dir inside it, §11; under Codex's `read-only` sandbox nothing is writable, `TMPDIR` included, so Codex agents then have no scratch space), so agents that need temporary files don't collide with each other or leave files in the project.
- **No acting outside the machine** (posting, commenting, sending messages, or changing issues, tickets, or other remote data), with any tool, since agents get the user's MCP servers (§11), some of which write, and a council would do it once per agent. Reading remote information stays allowed.
- **No test suites, builds, coverage tools, application servers, or database tasks unless the prompt permits them**, since such commands can collide through shared resources a per-agent scratch directory doesn't isolate: shared databases, Redis, fixed ports, Docker resources, hard-coded temporary paths, or other process-global state. Running tests and reproducing defects can make an analysis much stronger, so a prompt may lift the rule (as `examples/prompts/review-latest-commit-prompt.md` does for tests and linters); agents then still skip commands needing shared services. Where a command is not permitted but would help, the agent describes what it would run and why.

---

## 11. Harness Context Behavior

Useful real-world analysis matters more than establishing a laboratory benchmark, so each harness behaves as it normally would when analyzing a repository, except as listed below. There is no configurable controlled-comparison mode.

### Pi

Pi may automatically load project-specific context such as:

- `AGENTS.md`;
- project context files;
- skills;
- extensions;
- prompt templates.

The analyzed repository's own `.pi` resources load only if pi already trusts the project, since agent-council passes no `--approve`.

Pi's exceptions to normal behavior:

- each agent is independent;
- no conversation/session state leaks between agents (`--no-session`);
- the tool list is restricted and the scaffolding appended to the system prompt (§10);
- the report-format addendum is appended to each analyst's prompt.

### Claude Code

**Invocation.** One `claude` process per agent, the prompt on stdin, started from an argv array (§9):

```text
claude -p --output-format stream-json --verbose
       --no-session-persistence
       --tools Read,Grep,Glob,Bash --allowedTools Read,Grep,Glob,Bash
       --permission-mode manual
       --model MODEL
       --append-system-prompt SCAFFOLDING
```

The flags were checked with Claude Code 2.1.325, and again with 2.1.327 and 2.1.329 (and, for the comparison with pi's allowlist, pi 1.5.2):

- `--tools` limits the built-in tools as pi's allowlist does: Edit and Write are absent, not merely refused.
- `--allowedTools` is required. Without it, Bash commands Claude Code doesn't consider read-only (`git log` and `ls` are; `ruby -e ...` isn't) are refused, since `-p` mode can't ask, and the agent still ends as a success, with the refusal recorded only in the `result` event's `permission_denials`. With it, a call can still be refused, by a `permissions.deny` rule in the user's or the analyzed project's settings (checked: a project rule denying `Bash(cat:*)` was recorded the same way). A nonempty `permission_denials` is reported as a warning naming the refused calls (`ClaudeCodeHarness.warnings`), printed under the agent's progress line, shown in the report's byline table (which the consolidator reads, and which its template asks it to take into account), and recorded in its `run.json` entry, not a failure: the report is kept, but may lack what the call would have found. An agent that fails anyway (say, by running out of turns after refusals) gets the warning too, since the refusals may be why; it follows the failure reason on the console, in `run.json`, and in the reason the consolidation prompt gives for the missing report.
- `--permission-mode manual` makes the outcome the same for every user; without it the user's own `defaultMode` (e.g. `auto`, or `plan`, which would run nothing) applies (checked: with `defaultMode` set to `plan`, the `init` event reports `plan` without the flag and `default` with it). `manual` is the name `claude --help` lists for the mode the stream reports as `default`; `default` is still accepted but no longer listed, so it isn't used.

**Context.** Claude Code behaves as in an interactive session started in the analyzed repository, as pi does (above): it loads `CLAUDE.md` (and whatever it imports, such as `@AGENTS.md`), user and project settings, hooks, and plugins, and its auto memory for the project. Auto memory is kept deliberately (checked: the system prompt names the project's memory directory, shows its `MEMORY.md` index, and says to write memory files there; `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` removes all of it): the notes are context an interactive session would have, and leaving them out would make agents worse at the user's project. An agent may still write a memory file with `Bash`, as an interactive session may (the scaffolding's "strictly read-only" rules argue against it, but don't name memory); that is accepted, and the README says so. `--bare` is not used: it skips `CLAUDE.md` and permits only API-key authentication. Nor is `--safe-mode`, which keeps subscription authentication but also skips `CLAUDE.md`, along with skills, plugins, hooks, and other customizations (permission rules and admin-managed settings still apply); nor is `--restricted`, which ignores the user, project, and local settings files altogether, permission rules included, and so would drop both the user's own setup and a project's deny rules (untested); a user who wants that can set `CLAUDE_CODE_SAFE_MODE=1` (its environment form) when running agent-council, and the README's Safety section says so (checked: with it, a project's hooks didn't run and a subscription login still worked). So the user's hooks and plugins run for every Claude Code agent, and so do hooks in the analyzed repository's own `.claude` settings: `-p` mode skips the trust prompt an interactive session shows first in a new folder (checked: a never-trusted repository's `SessionStart` and `PreToolUse` hooks ran). The README's Safety section says so.

**Sandbox.** agent-council neither enables nor disables Claude Code's Bash sandbox; Claude Code's settings decide, including settings committed to the analyzed repository, which can enable it or disable one the user enabled (only `--settings` or managed settings take precedence). Commands matching `sandbox.excludedCommands`, which the repository's settings can add to, run outside it. The README's [Claude Code's sandbox](README.md#claude-codes-sandbox) gives users the details.

- Checked with Claude Code 2.1.325 on Ubuntu with AppArmor restricting unprivileged user namespaces: the distribution's `/usr/bin/bwrap` makes every Bash call fail with a `setgroups` error; a copy of `bwrap` at another path with its own AppArmor profile granting `userns` works (a copy without one fails). Claude Code's docs give a profile for `/usr/bin/bwrap` or a sysctl as the fixes. Claude Code runs the first `bwrap` on the `PATH` it inherits, and `claude` is run directly, not through a shell (§9), so a shell alias doesn't reach agents.
- Checked: a `TMPDIR` long enough to push the sandbox's Unix socket paths past about 108 bytes makes the sandbox fail to start and commands run unsandboxed. `Dir.mktmpdir` adds about 36 bytes to the user's temporary directory.
- Checked: with the sandbox enabled and its other settings at their defaults, network access and writes to the home directory outside the working directory were blocked.
- From Claude Code's sandboxing docs, not checked: the working directory stays writable apart from protected files (the `.claude` settings files, `.git/hooks`, and others); `sandbox.failIfUnavailable` makes Claude Code refuse to run commands unsandboxed when the sandbox is unavailable.
- Checked with 2.1.327, with agent-council's argv and the sandbox enabled: inside the sandbox `TMPDIR` is `<scratch>/claude-<uid>`, which is writable, while a write to the scratch path itself fails with "read-only file system". So the scaffolding names the scratch dir as `$TMPDIR`, not by path; `$TMPDIR` is the scratch dir itself for pi and unsandboxed Claude Code, and a dir inside it under the sandbox, so cleanup covers both. The sandbox makes that dir under `CLAUDE_CODE_TMPDIR` if set, so agent-council sets it to the scratch dir too; otherwise a user's own setting would put the dir outside, shared between agents and never removed (checked: with both set, the sandboxed `TMPDIR` was `<scratch>/claude-<uid>`). (`--add-dir` with the scratch path was the alternative; it would widen what Claude Code allows, and wasn't tried.) An unsandboxed retry (`dangerouslyDisableSandbox: true`) of a blocked home-directory write was refused ("Run outside of the sandbox") and reported in `permission_denials`, so agent-council warns of it, although the docs say an allow rule matching a command approves such a retry. Why agent-council's `--allowedTools Read,Grep,Glob,Bash` didn't approve it isn't known.
- agent-council doesn't detect other sandbox trouble: `ClaudeCodeHarness.warnings` reads only `permission_denials`.

**Billing.** agent-council leaves authentication and billing entirely to Claude Code: it passes no option and sets no environment variable for them (the only variables it sets for an agent are `TMPDIR` and `CLAUDE_CODE_TMPDIR`, both to its scratch dir, §10). An agent bills however `claude` would at the user's terminal: a subscription login, or an API key if one is configured. One caveat, which the README gives: interactive Claude Code asks before using an `ANTHROPIC_API_KEY` found in the environment, but `-p` mode doesn't ask, so a key exported for another tool may bill council runs to the API. Subscription runs also share the user's usage limits with their interactive work; a limit hit while an agent is working is expected to end it as an ordinary agent failure, but that hasn't been observed (§13). The reported cost is recorded unadjusted (only rounded to six decimal places); like other subscription providers' figures it is notional (the stream gives its `costBasis` as `list`). Telling billing sources apart in `run.json` is not built (§18); the sources for it are the `init` event's `apiKeySource` (`none` for a login), `claude auth status --json` (`subscriptionType`, e.g. `pro`), and the stream's `rate_limit_event`s, which give the plan's utilization of its 5-hour and weekly windows.

### Codex

**Invocation.** One `codex exec` process per agent, the prompt on stdin, started from an argv array (§9):

```text
codex exec --json --ephemeral --skip-git-repo-check --color never
           --model MODEL
           -c developer_instructions=SCAFFOLDING
           -
```

Checked with codex-cli 0.167.0:

- `-c developer_instructions=...` adds the scaffolding to the system prompt (checked: an instruction given this way was followed). It replaces any `developer_instructions` the user's config sets; Codex has no option that appends.
- `--skip-git-repo-check` is needed outside a git repository Codex trusts: without it Codex refuses ("Not inside a trusted directory"), while pi and Claude Code agents run anywhere.
- Codex's `read-only` and `workspace-write` sandboxes also block network access unless the user's config allows it (checked with `codex sandbox`: `curl` couldn't resolve a host under either, and worked unsandboxed).
- No `--sandbox` or approval option is passed: the user's `sandbox_mode` applies, as in an interactive session (§11's premise). The user's `approval_policy` doesn't: `codex exec` never asks, so a command that needs approval is refused (checked: an agent told `approval_policy="on-request"` reported `never`, and `"untrusted"` made `codex exec` exit with "no longer supported"). Under `read-only`, Codex's default, commands can write nothing, `$TMPDIR` included (checked: "read-only file system"), so agents get no scratch space although the scaffolding offers it; under `workspace-write`, `$TMPDIR` is writable (checked), and so is the analyzed repository. Forcing `read-only` was tried and dropped: it overrode the user's setting, and the scaffolding would have needed a variant without scratch space.
- No tool is withheld: this Codex version has no option for it. Codex agents keep `apply_patch` (file editing) and the subagent tools (`spawn_agent` and others); `--disable multi_agent`, `-c features.multi_agent=false`, and `-c include_apply_patch_tool=false` each left them in the rendered prompt (`codex debug prompt-input`). The README says so. The subagent tools fail, though: under `--ephemeral`, `spawn_agent` fails with "collab spawn failed: ... no rollout found for thread id" (on stderr; the stream shows only the agent's `wait`), and the agent carries on alone (checked with codex-cli 0.167.0). That also keeps usage whole: without `--ephemeral`, a subagent ran, and its tokens (31,708 input in its own session) were not in its parent's `turn.completed`, which matched the parent's session alone. If a Codex version lets `--ephemeral` agents spawn, usage will undercount them.
- MCP servers load; see below.

**Context.** Codex behaves as in an interactive session started in the analyzed repository: it loads the user's `config.toml`, skills, plugins, and hooks it trusts, and the project's `AGENTS.md` files (and its `.codex` config, if the user trusts the project; checked: skill instructions appear in the rendered prompt). `--ignore-user-config` is not used.

**Billing.** agent-council leaves authentication and billing to Codex: a ChatGPT login or an API key, however `codex` would bill at the user's terminal. The entry's provider only labels the agent; Codex uses the `model_provider` its config names.

### MCP servers load, in every harness

Agents get the MCP servers the user has configured for their harness, as an interactive session would: pi's (`~/.pi/agent/mcp.json`, a trusted project's, and extensions'), Claude Code's (the user's, plugins', and the project's approved ones), and Codex's (`config.toml`, plugins, the apps connectors, and a trusted project's). agent-council passes no MCP option. Leaving them out would make agents worse at the user's own work (a coverage server, an issue tracker, internal docs), which matters more here than isolation (§11's premise).

The cost is risk, which the README's Safety section states prominently. A server that writes (posting to chat, commenting on an issue, changing a ticket) is available to every agent, held back only by the scaffolding's read-only instructions, and a council would do it once per agent; and each agent starts every server it loads, so a server that acts merely by starting acts once per agent. The user's remedy is their own config (remove or disable the server), or an environment without it.

How each harness exposes the tools (checked with pi 1.5.2, Claude Code 2.1.329, and codex-cli 0.167.0, calling a `version` tool on a local stdio server):

- **pi** exposes MCP tools through its `codemode` tool by default, so `codemode` is in the `--tools` allowlist (checked: without it, agents had no MCP access). A server with direct exposure has its tools activated only if `--tools` names them, so `mcp__*` is listed too (checked: without it, a direct server's tool was unavailable). A server with deferred exposure has its tools loaded by `tool_search`, so that is listed as well; it loads only MCP tools (checked: `tool_search` for `write` and `edit` found nothing). Since naming an `mcp__` entry makes `--tools` filter MCP tools by name, pi's resource tools (`list_mcp_resources`, `list_mcp_resource_templates`, `read_mcp_resource`) are listed too. A `codemode` script can call only the allowlisted tools and MCP tools (checked: its `tools` object had them and the resource tools, and no `write`), plus pi's `models` API (`models.classify`, `models.generateImages`), which calls models itself; pi reports that usage on the `codemode` tool result, so `PiHarness.usage` counts tool results' usage along with assistant messages'. `tool_search` is listed for deferred exposure but also finds codemode-exposed tools, which `codemode` reaches anyway. Listing `codemode` activates it even when the user's pi settings set `autoEnableCodemode` to false; agents can't otherwise reach MCP tools with the default exposure. pi doesn't ask before a tool runs, so pi agents can call any MCP tool they get. A failed MCP call reaches a pi agent as a tool result marked `isError`, which the agent can read; agent-council doesn't warn of it (`PiHarness.warnings` returns none), unlike Claude Code's and Codex's refused calls, since a pi failure is an ordinary tool error, not a refusal, and pi reports a server that fails to start only in its interactive UI. Unlisted extension tools stay out of reach even with `codemode` and `tool_search`: pi drops tools the allowlist doesn't match before registering them, and both reach only registered tools (pi 1.5.2's `_refreshToolRegistry`, `_getCallableTools`).
- **Claude Code** loads the servers, but `-p` can't ask permission, so an MCP call goes through only if a permission rule allows it (e.g. `mcp__server` in `permissions.allow`); otherwise it is refused and lands in `permission_denials`, which `ClaudeCodeHarness.warnings` reports. MCP tools are not added to `--allowedTools`: that would give agents more than an interactive session has without the user's approval.
- **Codex** loads the servers, but `codex exec` never asks for approval, so an MCP call goes through only if the user's config approves the tool in advance (`default_tools_approval_mode = "approve"` on a server, or `approval_mode = "approve"` on one of its tools); otherwise the `mcp_tool_call` item fails with "MCP tool call requires approval, but approval policy is never", which `CodexHarness.warnings` reports.

0.2.0 and the Codex harness's first version turned MCP off instead (pi's `--no-mcp`, Claude Code's `--strict-mcp-config`, and for Codex a per-server `enabled=false` table built from `codex mcp list`, plus `--disable apps`). That was reversed: it crippled agents relative to the user's setup, and Codex's version was fragile (a plugin's server in the listing made the override fail with "invalid transport", failing every agent). `pi-models` still passes `--no-mcp`, since it only lists models and runs no agent.

---

## 12. Report Files

The models don't write their own report files.

The harness returns the final response to the Ruby process, which writes that text (minus any leading top-level heading), under front matter and a metadata table, to a deterministic, self-describing filename (see below).

Each run gets its own directory, a day bucket, and an `hh-mm-ss` time, created atomically with a `-2`, `-3`, ... suffix if that name is already taken, and printed when the run starts, so an in-progress or interrupted run is easy to find. [The README's "What you get" section](README.md#what-you-get) specifies the layout, filenames, query slug, and front matter; the decisions behind them are:

- **Inputs are copied into the run dir** (the prompt, config, and `analyst_format.md`, each under its own file name), so an analyst's inputs are recoverable later. The orchestrator is versioned in git and deliberately not copied; the harness and agent-council versions, the scaffolding text, and the consolidation template are not recorded.
- **Only analysts' reports go in `reviews/`.** The consolidator's reports (normally a findings and a meta file) and the input copies sit at the run dir root.
- **Filenames are self-describing.** They carry the full timestamp, query slug, agent index (`consolidated` for the consolidator), harness, provider, and model, so a report still says what it is when copied out of the tree. The agent index keeps names unique when a provider/model is configured more than once (e.g. to get several independent analyses from one model) and sits before the harness, so filenames sort in agent order with more than one harness. Provider and model are sanitized like the slug but keep their case.
- **Metadata is YAML front matter written by the orchestrator**, never by the model: it gives tools structured provenance, stays readable in the terminal, and is how reports are identified, so nothing parses filenames (a consolidation's findings file, meant to be pasted elsewhere, has identifying lines in place of front matter instead). Timestamps are unquoted ISO 8601, so they parse directly as `Time` objects. Beyond the `provider` and `model` every report needs to be recognized, `--consolidate` needs the analysts' `prompt_file`, `config_file`, `run_stamp`, and `query`, and their `agent_index` to tell which configured agents have no report.
- **Measurements go in `run.json`, not front matter.** Front matter identifies a document; an agent's duration and token usage are data about the agent, wanted for analysis across many runs, and most tools can't read front matter without tripping over the Markdown after it. So they go in one JSON file per run dir, readable by any language's standard library or `jq`; the byline table still shows a report's own duration and usage to its readers.

The optional consolidator (a top-level `consolidator:` entry in the
config, with a harness, provider, and model like an agent's; §5) runs
after all agents finish, as one more agent, under its own entry's harness,
with the tools and scaffolding an analyst gets under that harness. Its
prompt is `lib/agent_council/templates/consolidate_prompt.md` followed
by the original prompt, every analyst report labeled with its source,
and the agents without a report, each with its harness and its failure
reason and warnings (with `--consolidate`, as `run.json` records them,
else a note that the reason wasn't recorded). A consolidation failure is
reported but does not change a normal run's exit status
(`--consolidate`'s exit status is the consolidation's).

**The consolidated report is split into two files.** The consolidator is asked to write its findings, then a line containing only `=== META ===`, then the sections that describe the consultation (`Agent Consultants`, `Agent performance`), and the orchestrator splits the report at that line. The findings file has no front matter or orchestration tables (the consolidator's own findings may still contain tables), so it can be pasted into an AI chat without spending tokens on the rest; it carries a legend of agent number, harness, provider, and model, since the findings cite agents by number. The rest goes to a meta file. A marker line was chosen over parsing headings, which depended on the model's exact section names and on code fences, and over a JSON or YAML wrapper, where one unescaped quote or bad indent in thousands of tokens of Markdown would lose the whole report. If the marker is missing, repeated, inside a code fence, or not followed by the `Agent Consultants` heading (which makes a quoted one unlikely to be taken for the real one), or if the report no longer starts with the header written to it, the report is left unsplit, with a warning that says why, rather than guessed at, and so it is if a split file can't be written; the original single file is not kept after a successful split, to avoid duplicate text. The findings file has no front matter, so it opens with a few lines identifying its run instead, and `run.json` records the meta file, which has the front matter, next to it. The consolidator's report is first written under the meta file's name, which, being created exclusively, keeps the configuration taken against a concurrent consolidation, and then rewritten in place; a report that can't be split is renamed to the unsuffixed name, which releases the meta name, so that guard covers split reports only. Each report in the consolidator's prompt states its harness, so findings can be attributed to harness, provider, and model.

The orchestrator already knows model identity, so analysts aren't asked to report it; the consolidator gets each report's source label from the orchestrator.

---

## 13. Harness Output Parsing

Each harness reads its own event stream and decides what counts as a failure; the orchestrator reports a failure, and saves nothing for it, whichever harness found it.

### Pi

agent-council reads pi's JSONL event stream (`--mode json`) rather than scraping human-oriented terminal output. Pi documents `message_end` as the authoritative final message of a turn, so the final response is the text of the last assistant `message_end` event that has text (a trailing text-less message doesn't hide an earlier report). Pi exits 0 even when the provider rejects the request, so a non-blank `errorMessage`, or a `stopReason` of `length`, `aborted`, or `error` (output cut off, cancelled, or failed without an `errorMessage`), counts as a failure. Only the last assistant message and the one that would be saved are checked, so an error in a turn that a later turn recovered from is not a failure. Failures are reported, not saved as reports.

Parsing extracts only that; there is no generic Pi protocol library.

The parser and the pi CLI invocation for agents live in `AgentCouncil::Harnesses::PiHarness`
(`lib/agent_council/harnesses/pi_harness.rb`), the single home of pi-specific
behavior for agents (the separate `pi-models` helper also talks to pi); see §4
for how the orchestration finds it.

### Claude Code

agent-council reads Claude Code's `stream-json` output. The stream's final `result` event carries everything needed, so parsing is simpler than pi's:

- the report is its `result` text;
- the agent failed if there is no `result` event, `is_error` is true, or the text is blank. Every failure observed (not logged in, an unknown model, output over the token limit, the turn limit) exited 1 with `is_error` true, but `subtype` was `success` for all but the turn limit (`error_max_turns`), and a cut-off output reported no `max_tokens` stop reason, so neither is checked;
- the failure's reason is the `result` event's `errors`, if any (e.g. "Reached maximum number of turns (1)", with an empty `result`), otherwise its `result` text (e.g. "Not logged in · Please run /login"). Stderr was empty in all but one case, so unlike pi's, a nonzero exit is explained from the stream, with stderr only as a fallback;
- usage is read from the `result` event alone, which totals the agent's whole session; the per-message `assistant` events carry partial snapshots that undercount output (in one recorded case, 16 output tokens where the `result` event gave 184). So an agent that ends without a `result` event, as when its `claude` is killed, reports no usage rather than a misleading partial count, unlike a pi agent, whose completed messages each report their full usage. It maps `input_tokens`, `output_tokens`, `cache_read_input_tokens`, and `cache_creation_input_tokens` to `input`, `output`, `cache_read`, and `cache_write` (as with pi, `input` excludes cache reads and writes), and `total_cost_usd` to `cost`.

So `exit_detail`, which explains a nonzero exit, reads the stream first for Claude Code (and Codex, below) and stderr for pi. The parser and the invocation live in `AgentCouncil::Harnesses::ClaudeCodeHarness` (`lib/agent_council/harnesses/claude_code_harness.rb`). The specs read streams recorded from real `claude` invocations (`spec/fixtures/claude_code/`), trimmed to a few event types and fields, with local paths, tool call IDs, and commit hashes replaced by placeholders; the spec's header says how each was recorded.

Not yet observed for Claude Code: an agent that hits a usage limit, and one billed to an API key.

### Codex

agent-council reads `codex exec --json`'s event stream:

- the report is the text of the last `agent_message` item with text, in a turn that ended in `turn.completed` (earlier agent messages narrate tool use; a trailing blank one, not observed, would not hide the report, as for pi);
- the agent failed if there is no `turn.completed` or `turn.failed` event, the turn ended in `turn.failed`, or the completed turn has no message text. An unsupported model exited 1 with `turn.failed` whose `error.message` gave the reason, and an empty stderr; so, as for Claude Code, a nonzero exit is explained from the stream (`turn.failed`, else the last top-level `error` event), with stderr as a fallback;
- `error` items that don't fail the turn (e.g. "Model metadata for `x` not found") become one warning listing at most five distinct messages, each cut to 200 characters, and failed `mcp_tool_call` items (e.g. a call refused for want of approval, §11) another, listing at most five distinct `server.tool (reason)` entries (just `tool` when the server is missing, `unknown tool` when the tool is), cut the same way;
- usage comes from `turn.completed`. Codex's `input_tokens` counts all input, as OpenAI's API does, so `cached_input_tokens` and `cache_write_input_tokens` are subtracted from it for `input` (as with pi, `input` excludes cache reads and writes); reasoning tokens are part of `output_tokens`. Codex prices nothing, so there is no `cost`, and a run's total cost (`total_usage`'s `cost`) is omitted when a Codex agent reported usage (an agent with no usage, e.g. one that failed, is left out of the total); the console summary then gives the other analysts' known cost, and `run.json`'s `known_cost` and `known_cost_runs` that of every entry with one. A ChatGPT login always reported 0 cache writes, so the subtraction of writes is untested against real output.

The parser and the invocation live in `AgentCouncil::Harnesses::CodexHarness` (`lib/agent_council/harnesses/codex_harness.rb`). The specs read streams recorded from real `codex` invocations (`spec/fixtures/codex/`), with the thread ID zeroed and command items replaced by placeholders.

Not yet observed for Codex: an agent that hits a usage limit, and one billed to an API key.

---

## 14. Output Directory

Reports go into `agent-council-reports/` under the current working
directory — i.e. the repository being analyzed — so the tool can be run
from any project:

```text
agent-council-reports/
```

The name says which tool wrote the directory, since it lands in someone
else's tree. `-o` / `--output-dir` (given directly or in `AGENT_COUNCIL_OPTS`)
replaces only this base directory; everything beneath it is the same. The
README's [Running](README.md#running) section has the rules.

Each run writes a timestamped, day-bucketed run directory (see §12), so
repeated runs accumulate without overwriting; beyond `--consolidate` (§6),
no run management is implemented.

---

## 15. Basic Failure Handling

Failure handling is simple. If a harness invocation fails, agent-council:

- prints a useful error;
- writes no report for it;
- lets the other agents finish.

One failed model doesn't discard successful results from others. The
README's [What you get](README.md#what-you-get) section shows how
failures are reported.

There are no retries of agent-council's own (the harnesses may retry transient provider failures), error taxonomies, fallback models, semantic report validation, or separate process/report status systems.

---

## 16. Repository Layout

```text
README.md
INSTALL.md
USE_CASES.md
DESIGN.md
RELEASE_NOTES.md
LICENSE.txt
REVIEW_NOTES.md          # settled review findings; not shipped in the gem
CONTRIBUTING.md          # contribution process; not shipped in the gem
agent-council.gemspec
exe/                     # executable entry points; nearly all code lives in lib/
  agent-council
  pi-models              # helper: list models available to pi
lib/
  agent_council.rb       # harness-agnostic orchestration (AgentCouncil)
  agent_council/
    version.rb
    platform.rb          # windows? and the native-Windows abort (WSL is required)
    pi_models.rb         # backs exe/pi-models
    worker_pool.rb       # worker threads, agent processes, and Ctrl-C handling
    harnesses.rb         # harnesses by name (AgentCouncil::Harnesses)
    harnesses/
      scaffold.rb        # the read-only scaffolding every harness appends
      pi_harness.rb      # pi-specific behavior (AgentCouncil::Harnesses::PiHarness)
      claude_code_harness.rb  # Claude Code-specific behavior (ClaudeCodeHarness)
      codex_harness.rb   # Codex-specific behavior (CodexHarness)
    templates/           # runtime data files (resolved via __dir__, shipped in the gem)
      consolidate_prompt.md  # instructions template for the consolidator
      analyst_format.md      # report-format addendum for analysts
spec/                    # RSpec; not shipped in the gem

examples/                # pure, non-runtime samples (prompts/ and configs/ ship in the gem)
  prompts/
    smoke-test-prompt.md
    state-of-the-code-base-prompt.md
    project-name-prompt.md
    recommend-model-ensemble-prompt.md
    review-latest-commit-prompt.md
    review-docs-prompt.md
    test-coverage-analysis-prompt.md
  configs/
    single.yml
    consolidated.yml
    mixed-harness.yml
  results/               # sample output; not shipped in the gem

agent-council-reports/   # created on demand; gitignored in this repository
```

Dev-only files (Gemfile, Rakefile, lint configs, CI workflows, `bin/setup`,
`bin/setup-hooks`, `hooks/pre-commit`) are omitted above. The gemspec's
`spec.files` is the authority on what ships.

`lib/` stays shallow, without namespaces deeper than `harnesses/`
(such as `lib/agent_council/services/...`) unless the project grows enough to
require them. A plain implementation is preferred to a speculative
framework.

---

## 17. Dependencies

The tool itself uses only the Ruby standard library (`yaml`, `json`, `open3`, `optparse`, `fileutils`, `tmpdir`, `shellwords`, ...); tests use RSpec.

New gems are added only if they solve a meaningful problem that would otherwise require substantial code.

---

## 18. Status and Future Work

agent-council is at an early stage (0.x), so it does only what its core job needs. Features we hope to add include support for more harnesses and telling a Claude Code agent's billing source (subscription or API key) apart in `run.json` (§11). A missing feature is usually just not built yet.

`REVIEW_NOTES.md` separately tracks review findings that were considered and don't need to be re-raised: accepted risks and non-issues.

---

## 19. Design Rule

Every proposed feature should pass this test:

> Does this help get independent answers to the same prompt from multiple models, or make sense of them?

If not, leave it out. Consolidation passes; a general-purpose agent framework does not.
