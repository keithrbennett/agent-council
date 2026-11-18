# Design

## 1. Goal

The long-term goal is to collect genuinely different viewpoints on the same question from multiple harness/model instances, and, because every instance gets the identical task, to compare those instances against each other on speed, token usage, cost, and quality.

This repository is the first step: it varies the models and, per agent, the harness, which is Pi (for any provider's models) or Claude Code (for Anthropic's). More harnesses may follow (§18).

It is packaged as a gem for easy installation, but it is intentionally not a general-purpose framework.

agent-council is a small Ruby CLI that runs the **same prompt** through several AI harness/provider/model combinations, under the Pi or Claude Code coding-agent harness, and saves each final response to a deterministic Markdown file.

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

There are two harnesses, pi and Claude Code, and the orchestration is harness-agnostic: it looks up each agent's harness module by its config entry's `harness` key (§5) in `AgentCouncil::Harnesses::BY_NAME` (`lib/agent_council/harnesses.rb`), so another harness is another such module, added there. Every config entry names its harness (§5); reports and `run.json` entries always record theirs, and one that gives none (hand-edited, or older than 0.1.0, when every agent ran under pi) is read as pi's. Each module is a plain namespace with the same functions (`NAME`, `argv`, `usage`, `error_message`, `exit_detail`, `warnings`, `final_response`, `assistant_messages`); `NAME` is both the config value and the executable that `argv` runs, which the startup check looks for on `PATH`, and goes into filenames unsanitized, so it must be filename-safe. Claude Code takes no provider argument, so a Claude Code entry's provider only labels the run. The scaffolding text (§10) is shared.

**Labels.** The short labels (`#1 provider / model`) don't show the harness. They appear in progress lines, result tables, the consolidation prompt, and a consolidated report's `### Sources` table and `sources` front matter. The startup agent list, each report's byline table, and the findings file's legend (`#1 pi / provider / model`) do show it. Short labels don't need the harness to stay unique: the only ones used as lookup keys are the analysts', which match reports to their `run.json` entries and to the configured agents, and each carries its agent number. Nor does the consolidator need it in the labels, since each report it reads states its harness in its byline (§12). So they stay as they are, and a mixed run's output reads the same as before.

The Ruby program owns orchestration and invokes the harness once per configured agent.

```text
Ruby CLI
   |
   +-- Pi + model A
   +-- Pi + model B
   +-- Claude Code + model C
   +-- Claude Code + model D
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

  - harness: claude        # Claude Code; the provider only labels the run
    provider: anthropic
    model: MODEL_ID_HERE

consolidator:              # optional; synthesizes the agents' reports (§12)
  harness: pi
  provider: anthropic
  model: MODEL_ID_HERE
```

Every entry gives `harness`, `provider`, and `model`, each a nonblank string; there are no defaults, and no `defaults:` section supplying them (one was considered and rejected). A default harness or provider would go stale as harnesses change (pi is the right default only as long as it is), and a `defaults:` section's provider would apply across harnesses whose providers differ. `harness` is `pi` or `claude`; an unknown one is rejected at startup (with `--consolidate`, only the consolidator's, since no analysts run). A `claude` entry's provider is not passed to Claude Code (§4) and only labels the run (e.g. `bedrock`, for a `claude` set up to use it). A config error lists every bad entry, each named by its key (`'agents' entry #2`, `'consolidator'`) with every problem it has, so one edit fixes them all; when an entry gives no harness, a line saying what every entry needs follows, and, if no entry gives one (as in a 0.1.0 config, which ran everything under pi), a hint to add `harness: pi`. A run made by 0.1.0, when every entry ran under pi, has a config copy without `harness`; `--consolidate` rejects its consolidator like any other entry, with a hint to add `harness: pi`, while its reports and `run.json` are still read as pi's.

Exact provider and model identifiers must be verified against the installed harness: `pi --list-models` for pi, and the names and aliases `claude --model` accepts for Claude Code.

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
3. launches all configured analyst runs;
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
- **Agents get SIGTERM and a shared grace period before being killed**, so the harness can stop the commands it started (pi and Claude Code do; checked for Claude Code 2.1.325: a command its Bash tool was running, in the foreground or with `run_in_background`, ran in a process group of its own, which agent-council's SIGTERM to the agent's group doesn't reach, and ended when `claude` got SIGTERM); a second signal skips the wait for a user who doesn't want to.
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

The scaffolding appended to each agent's system prompt (`Harnesses.scaffold_text` in `lib/agent_council/harnesses/scaffold.rb`, shared by every harness) states the rules agents get, and the README's [How it works](README.md#how-it-works-and-what-the-agents-are-told) section summarizes them. They are instructions, not enforced restrictions: each harness's tool limit (pi's `--tools` allowlist, which activates only the tools it lists; Claude Code's `--tools`) and its MCP setting (§11) are the only restrictions agent-council enforces (Claude Code's own sandbox can also restrict Claude Code agents if Claude Code's settings enable it, and the analyzed repository's settings can enable or disable it; §11), and the shell tool remains a full shell running as the user (see the README's [Safety and privacy](README.md#safety-and-privacy)). A shell is kept because investigation (`git log`, dependency inspection, running a documented command) is much of what makes an analysis useful.

The rules follow from agents running concurrently in the user's own working tree:

- **No modifying project files, git state, software, or configuration, and no persistent services**, since the agents analyze the user's real repository and environment, not a copy. If testing a proposed change would need a modified file, the agent should describe the experiment instead (this follows from the rule; the scaffolding doesn't state it separately).
- **Each agent gets its own disposable scratch directory** (its `TMPDIR`, which the scaffolding names rather than giving a path: under Claude Code's sandbox the dir itself is read-only and `TMPDIR` is a writable dir inside it, §11), so agents that need temporary files don't collide with each other or leave files in the project.
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

- each model run is independent;
- no conversation/session state leaks between runs (`--no-session`);
- pi's built-in MCP support is off (`--no-mcp`), so configured MCP servers don't start, which keeps any from doing something merely by starting, and agents have no MCP tools; an extension providing its own MCP support isn't affected, and extensions load as usual;
- the tool list is restricted and the scaffolding appended to the system prompt (§10);
- the report-format addendum is appended to each analyst's prompt.

### Claude Code

**Invocation.** One `claude` process per agent, the prompt on stdin, started from an argv array (§9):

```text
claude -p --output-format stream-json --verbose
       --no-session-persistence
       --tools Read,Grep,Glob,Bash --allowedTools Read,Grep,Glob,Bash
       --permission-mode manual
       --strict-mcp-config
       --model MODEL
       --append-system-prompt SCAFFOLDING
```

The flags were checked with Claude Code 2.1.325, and again with 2.1.327 (and, for the comparison with pi's allowlist, pi 1.5.2):

- `--tools` limits the built-in tools as pi's allowlist does: Edit and Write are absent, not merely refused.
- `--allowedTools` is required. Without it, Bash commands Claude Code doesn't consider read-only (`git log` and `ls` are; `ruby -e ...` isn't) are refused, since `-p` mode can't ask, and the run still ends as a success, with the refusal recorded only in the `result` event's `permission_denials`. With it, a call can still be refused, by a `permissions.deny` rule in the user's or the analyzed project's settings (checked: a project rule denying `Bash(cat:*)` was recorded the same way). A nonempty `permission_denials` is reported as a warning naming the refused calls (`ClaudeCodeHarness.warnings`), printed under the run's progress line, shown in the report's byline table (which the consolidator reads, and which its template asks it to take into account), and recorded in its `run.json` entry, not a failure: the report is kept, but may lack what the call would have found. A run that fails anyway (say, by running out of turns after refusals) gets the warning too, since the refusals may be why; it follows the failure reason on the console, in `run.json`, and in the reason the consolidation prompt gives for the missing report.
- `--permission-mode manual` makes the outcome the same for every user; without it the user's own `defaultMode` (e.g. `auto`, or `plan`, which would run nothing) applies (checked: with `defaultMode` set to `plan`, the `init` event reports `plan` without the flag and `default` with it). `manual` is the name `claude --help` lists for the mode the stream reports as `default`; `default` is still accepted but no longer listed, so it isn't used.
- `--strict-mcp-config` with no `--mcp-config` loads no MCP servers: `init` reports `mcp_servers: []` even for a user with servers configured, and a plugin that provides MCP tools doesn't load, while other plugins do (checked). Not tested: an enterprise `managed-mcp.json`, under which Claude Code's binary has the message "You cannot use --strict-mcp-config when an enterprise MCP config is present", so Claude Code agents would presumably fail there; the README notes it.

**Context.** Claude Code behaves as in an interactive session started in the analyzed repository, as pi does (above): it loads `CLAUDE.md` (and whatever it imports, such as `@AGENTS.md`), user and project settings, hooks, and plugins, and its auto memory for the project. Auto memory is kept deliberately (checked: the system prompt names the project's memory directory, shows its `MEMORY.md` index, and says to write memory files there; `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` removes all of it): the notes are context an interactive session would have, and leaving them out would make agents worse at the user's project. An agent may still write a memory file with `Bash`, as an interactive session may (the scaffolding's "strictly read-only" rules argue against it, but don't name memory); that is accepted, and the README says so. `--bare` is not used: it skips `CLAUDE.md` and permits only API-key authentication. Nor is `--safe-mode`, which keeps subscription authentication but also skips `CLAUDE.md`, along with skills, plugins, hooks, and other customizations (permission rules and admin-managed settings still apply); nor is `--restricted`, which ignores the user, project, and local settings files altogether, permission rules included, and so would drop both the user's own setup and a project's deny rules (untested); a user who wants that can set `CLAUDE_CODE_SAFE_MODE=1` (its environment form) when running agent-council, and the README's Safety section says so (checked: with it, a project's hooks didn't run and a subscription login still worked). So the user's hooks and plugins run for every Claude Code agent, and so do hooks in the analyzed repository's own `.claude` settings: `-p` mode skips the trust prompt an interactive session shows first in a new folder (checked: a never-trusted repository's `SessionStart` and `PreToolUse` hooks ran). The README's Safety section says so.

**Sandbox.** agent-council neither enables nor disables Claude Code's Bash sandbox; Claude Code's settings decide, including settings committed to the analyzed repository, which can enable it or disable one the user enabled (only `--settings` or managed settings take precedence). Commands matching `sandbox.excludedCommands`, which the repository's settings can add to, run outside it. The README's [Claude Code's sandbox](README.md#claude-codes-sandbox) gives users the details.

- Checked with Claude Code 2.1.325 on Ubuntu with AppArmor restricting unprivileged user namespaces: the distribution's `/usr/bin/bwrap` makes every Bash call fail with a `setgroups` error; a copy of `bwrap` at another path with its own AppArmor profile granting `userns` works (a copy without one fails). Claude Code's docs give a profile for `/usr/bin/bwrap` or a sysctl as the fixes. Claude Code runs the first `bwrap` on the `PATH` it inherits, and `claude` is run directly, not through a shell (§9), so a shell alias doesn't reach agents.
- Checked: a `TMPDIR` long enough to push the sandbox's Unix socket paths past about 108 bytes makes the sandbox fail to start and commands run unsandboxed. `Dir.mktmpdir` adds about 36 bytes to the user's temporary directory.
- Checked: with the sandbox enabled and its other settings at their defaults, network access and writes to the home directory outside the working directory were blocked.
- From Claude Code's sandboxing docs, not checked: the working directory stays writable apart from protected files (the `.claude` settings files, `.git/hooks`, and others); `sandbox.failIfUnavailable` makes Claude Code refuse to run commands unsandboxed when the sandbox is unavailable.
- Checked with 2.1.327, with agent-council's argv and the sandbox enabled: inside the sandbox `TMPDIR` is `<scratch>/claude-<uid>`, which is writable, while a write to the scratch path itself fails with "read-only file system". So the scaffolding names the scratch dir as `$TMPDIR`, not by path; `$TMPDIR` is the scratch dir itself for pi and unsandboxed Claude Code, and a dir inside it under the sandbox, so cleanup covers both. The sandbox makes that dir under `CLAUDE_CODE_TMPDIR` if set, so agent-council sets it to the scratch dir too; otherwise a user's own setting would put the dir outside, shared between agents and never removed (checked: with both set, the sandboxed `TMPDIR` was `<scratch>/claude-<uid>`). (`--add-dir` with the scratch path was the alternative; it would widen what Claude Code allows, and wasn't tried.) An unsandboxed retry (`dangerouslyDisableSandbox: true`) of a blocked home-directory write was refused ("Run outside of the sandbox") and reported in `permission_denials`, so agent-council warns of it, although the docs say an allow rule matching a command approves such a retry. Why agent-council's `--allowedTools Read,Grep,Glob,Bash` didn't approve it isn't known.
- agent-council doesn't detect other sandbox trouble: `ClaudeCodeHarness.warnings` reads only `permission_denials`.

**Billing.** agent-council leaves authentication and billing entirely to Claude Code: it passes no option and sets no environment variable for them (the only variables it sets for an agent are `TMPDIR` and `CLAUDE_CODE_TMPDIR`, both to its scratch dir, §10). An agent bills however `claude` would at the user's terminal: a subscription login, or an API key if one is configured. One caveat, which the README gives: interactive Claude Code asks before using an `ANTHROPIC_API_KEY` found in the environment, but `-p` mode doesn't ask, so a key exported for another tool may bill council runs to the API. Subscription runs also share the user's usage limits with their interactive work; a limit hit mid-run is expected to end the run as an ordinary agent failure, but that hasn't been observed (§13). The reported cost is recorded unadjusted (only rounded to six decimal places); like other subscription providers' figures it is notional (the stream gives its `costBasis` as `list`). Telling billing sources apart in `run.json` is not built (§18); the sources for it are the `init` event's `apiKeySource` (`none` for a login), `claude auth status --json` (`subscriptionType`, e.g. `pro`), and the stream's `rate_limit_event`s, which give the plan's utilization of its 5-hour and weekly windows.

### No MCP, in either harness

Agents get no MCP servers, so neither harness offers MCP tools (their built-in tools differ, as listed above), and no agent can reach a server that writes (posting to chat, commenting on an issue), which a council would do once per agent. Pi is passed `--no-mcp` (above), which turns off its built-in MCP support (an extension providing its own is unaffected) and in a test kept a project's server from starting; before that, its `--tools` allowlist already kept agents from calling MCP tools, but pi still started the user's servers. There is no setting to turn MCP on. If one is wanted later, it goes in the config, not on the command line, and names the servers to allow rather than switching all of them on, since enabling means per-harness work: pi's allowlist would have to name the MCP tools, and Claude Code would need them in `--allowedTools`.

---

## 12. Report Files

The models don't write their own report files.

The harness returns the final response to the Ruby process, which writes that text (minus any leading top-level heading), under front matter and a metadata table, to a deterministic, self-describing filename (see below).

Each run gets its own directory, a day bucket, and an `hh-mm-ss` time, created atomically with a `-2`, `-3`, ... suffix if that name is already taken, and printed when the run starts, so an in-progress or interrupted run is easy to find. [The README's "What you get" section](README.md#what-you-get) specifies the layout, filenames, query slug, and front matter; the decisions behind them are:

- **Inputs are copied into the run dir** (the prompt, config, and `analyst_format.md`, each under its own file name), so an analyst run's inputs are recoverable later. The orchestrator is versioned in git and deliberately not copied; the harness and agent-council versions, the scaffolding text, and the consolidation template are not recorded.
- **Only analysts' reports go in `reviews/`.** The consolidator's reports (normally a findings and a meta file) and the input copies sit at the run dir root.
- **Filenames are self-describing.** They carry the full timestamp, query slug, agent index (`consolidated` for the consolidator), harness, provider, and model, so a report still says what it is when copied out of the tree. The agent index keeps names unique when a provider/model is configured more than once (e.g. to get several independent analyses from one model) and sits before the harness, so filenames sort in agent order with more than one harness. Provider and model are sanitized like the slug but keep their case.
- **Metadata is YAML front matter written by the orchestrator**, never by the model: it gives tools structured provenance, stays readable in the terminal, and is how reports are identified, so nothing parses filenames (a consolidation's findings file, meant to be pasted elsewhere, has identifying lines in place of front matter instead). Timestamps are unquoted ISO 8601, so they parse directly as `Time` objects. Beyond the `provider` and `model` every report needs to be recognized, `--consolidate` needs the analysts' `prompt_file`, `config_file`, `run_stamp`, and `query`, and their `agent_index` to tell which configured agents have no report.
- **Measurements go in `run.json`, not front matter.** Front matter identifies a document; a run's duration and token usage are data about the run, wanted for analysis across many runs, and most tools can't read front matter without tripping over the Markdown after it. So they go in one JSON file per run dir, readable by any language's standard library or `jq`; the byline table still shows a report's own duration and usage to its readers.

The optional consolidator (a top-level `consolidator:` entry in the
config, with a harness, provider, and model like an agent's; §5) runs
after all agents finish, as one more run, under its own entry's harness,
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

The parser and the pi CLI invocation for runs live in `AgentCouncil::Harnesses::PiHarness`
(`lib/agent_council/harnesses/pi_harness.rb`), the single home of pi-specific
behavior for runs (the separate `pi-models` helper also talks to pi); see §4
for how the orchestration finds it.

### Claude Code

agent-council reads Claude Code's `stream-json` output. The stream's final `result` event carries everything needed, so parsing is simpler than pi's:

- the report is its `result` text;
- the run failed if there is no `result` event, `is_error` is true, or the text is blank. Every failure observed (not logged in, an unknown model, output over the token limit, the turn limit) exited 1 with `is_error` true, but `subtype` was `success` for all but the turn limit (`error_max_turns`), and a cut-off output reported no `max_tokens` stop reason, so neither is checked;
- the failure's reason is the `result` event's `errors`, if any (e.g. "Reached maximum number of turns (1)", with an empty `result`), otherwise its `result` text (e.g. "Not logged in · Please run /login"). Stderr was empty in all but one case, so unlike pi's, a nonzero exit is explained from the stream, with stderr only as a fallback;
- usage is read from the `result` event alone, which totals the whole run; the per-message `assistant` events carry partial snapshots that undercount output (in a recorded run, 16 output tokens where the `result` event gave 184). So a run that ends without a `result` event, as when its `claude` is killed, reports no usage rather than a misleading partial count, unlike a pi run, whose completed messages each report their full usage. It maps `input_tokens`, `output_tokens`, `cache_read_input_tokens`, and `cache_creation_input_tokens` to `input`, `output`, `cache_read`, and `cache_write` (as with pi, `input` excludes cache reads and writes), and `total_cost_usd` to `cost`.

So `exit_detail`, which explains a nonzero exit, reads the stream first for Claude Code and stderr for pi. The parser and the invocation live in `AgentCouncil::Harnesses::ClaudeCodeHarness` (`lib/agent_council/harnesses/claude_code_harness.rb`). The specs read streams recorded from real runs (`spec/fixtures/claude_code/`), trimmed to a few event types and fields, with local paths, tool call IDs, and commit hashes replaced by placeholders; the spec's header says how each was recorded.

Not yet observed: a run that hits a usage limit, and one billed to an API key.

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
- lets the other model runs finish.

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

agent-council is at an early stage (0.x), so it does only what its core job needs. Features we hope to add include support for more harnesses (such as Codex) and telling a Claude Code run's billing source (subscription or API key) apart in `run.json` (§11). A missing feature is usually just not built yet.

`REVIEW_NOTES.md` separately tracks review findings that were considered and don't need to be re-raised: accepted risks and non-issues.

---

## 19. Design Rule

Every proposed feature should pass this test:

> Does this help get independent answers to the same prompt from multiple models, or make sense of them?

If not, leave it out. Consolidation passes; a general-purpose agent framework does not.
