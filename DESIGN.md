# Design

## 1. Goal

The long-term goal is to collect genuinely different viewpoints on the same question from multiple harness/model instances.

This repository is the first step: it varies only the models, under a single harness (Pi). Harness diversity comes later (§18).

It is packaged as a gem for easy installation, but it is intentionally not a general-purpose framework.

agent-council is a small Ruby CLI that runs the **same prompt** through several AI model/provider combinations using the Pi coding-agent harness and saves each final response to a deterministic Markdown file.

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
      Pi + Claude    Pi + Kimi      Pi + GLM
          |             |             |
          v             v             v
       report         report         report
```

---

## 4. Architecture

Pi is the only harness.

The Ruby program owns orchestration and invokes Pi once per configured provider/model combination.

```text
Ruby CLI
   |
   +-- Pi + model A
   +-- Pi + model B
   +-- Pi + model C
   +-- Pi + model D
```

---

## 5. Configuration

A simple YAML file defines the ensemble.

Example:

```yaml
agents:
  - provider: anthropic
    model: MODEL_ID_HERE

  - provider: openai
    model: MODEL_ID_HERE

  - provider: opencode-go
    model: MODEL_ID_HERE

  - provider: zai
    model: MODEL_ID_HERE

consolidator:              # optional; synthesizes the agents' reports (§12)
  provider: anthropic
  model: MODEL_ID_HERE
```

Exact provider and model identifiers must be verified against the installed Pi version.

They belong in configuration because available models and names change frequently.

---

## 6. CLI

Command:

```bash
agent-council [-o DIR] PROMPT_FILE [CONFIG_FILE]
agent-council --consolidate RUN_DIR
```

The README's [Running](README.md#running) section and `agent-council -h`
document the arguments, options and `AGENT_COUNCIL_OPTS`. The command:

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

Agents run concurrently, one Ruby thread per agent, each driving one pi process.

`AgentCouncil::WorkerPool` (`lib/agent_council/worker_pool.rb`) also handles signals, keeping the main thread free to take them. The README's [Stopping a run](README.md#stopping-a-run) section describes what Ctrl-C and the other signals do; the reasons behind that behavior are:

- **Each agent leads its own process group**, so the terminal's signals reach only agent-council, which then stops the agents itself, in an orderly way, and Ctrl-Z suspends agent-council without suspending the agents under it.
- **Agents get SIGTERM and a shared grace period before being killed**, so pi can stop the commands it started; a second signal skips the wait for a user who doesn't want to.
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

Execution metadata stays outside the substantive prompt: the per-agent scratch path is in the system-prompt scaffolding, and model identity is in the report's front matter.

---

## 9. Prompt Delivery

The prompt is piped to pi on stdin, never interpolated into a command line, so it may be large and contain:

- Markdown;
- source code;
- quotes;
- shell characters;
- Unicode;
- long analytical instructions.

pi is started with an argv array, not through a shell.

---

## 10. Repository and System Safety

Agents are analyzers, not modifiers.

The scaffolding appended to pi's system prompt (`PiHarness.scaffold_text` in `lib/agent_council/harnesses/pi_harness.rb`) states the rules agents get, and the README's [How it works](README.md#how-it-works-and-what-pi-is-told) section summarizes them. They are instructions, not enforced restrictions: the `--tools` allowlist, which activates only the tools it lists, is the only enforcement, and `bash` remains a full shell running as the user (see the README's [Safety and privacy](README.md#safety-and-privacy)). A shell is kept because investigation (`git log`, dependency inspection, running a documented command) is much of what makes an analysis useful.

The rules follow from agents running concurrently in the user's own working tree:

- **No modifying project files, git state, software or configuration, and no persistent services**, since the agents analyze the user's real repository and environment, not a copy. If testing a proposed change would need a modified file, the agent should describe the experiment instead (this follows from the rule; the scaffolding doesn't state it separately).
- **Each agent gets its own disposable scratch directory** (also its `TMPDIR`), so agents that need temporary files don't collide with each other or leave files in the project.
- **No test suites, builds, coverage tools, application servers or database tasks unless the prompt permits them**, since such commands can collide through shared resources a per-agent scratch directory doesn't isolate: shared databases, Redis, fixed ports, Docker resources, hard-coded temporary paths, or other process-global state. Running tests and reproducing defects can make an analysis much stronger, so a prompt may lift the rule (as `examples/prompts/review-latest-commit-prompt.md` does for tests and linters); agents then still skip commands needing shared services. Where a command is not permitted but would help, the agent describes what it would run and why.

---

## 11. Pi Context Behavior

Pi may automatically load project-specific context such as:

- `AGENTS.md`;
- project context files;
- skills;
- extensions;
- prompt templates.

The analyzed repository's own `.pi` resources load only if pi already trusts the project, since agent-council passes no `--approve`.

Useful real-world analysis matters more than establishing a laboratory benchmark.

Therefore Pi behaves as it normally would when analyzing a repository, except that:

- each model run is independent;
- no conversation/session state leaks between runs (`--no-session`);
- the tool list is restricted and the scaffolding appended to the system prompt (§10);
- the report-format addendum is appended to each analyst's prompt.

There is no configurable controlled-comparison mode.

---

## 12. Report Files

The models don't write their own report files.

Pi returns the final response to the Ruby process, which writes that text (minus any leading top-level heading), under front matter and a metadata table, to a deterministic, self-describing filename (see below).

Each run gets its own directory, a day bucket and an `hh-mm-ss` time, created atomically with a `-2`, `-3`, ... suffix if that name is already taken, and printed when the run starts, so an in-progress or interrupted run is easy to find. [The README's "What you get" section](README.md#what-you-get) specifies the layout, filenames, query slug and front matter; the decisions behind them are:

- **Inputs are copied into the run dir** (the prompt, config and `analyst_format.md`, each under its own file name), so an analyst run's inputs are recoverable later. The orchestrator is versioned in git and deliberately not copied; the pi and agent-council versions, the scaffolding text and the consolidation template are not recorded.
- **Only analysts' reports go in `reviews/`.** The consolidator's report and the input copies sit at the run dir root.
- **Filenames are self-describing.** They carry the full timestamp, query slug, agent index (`consolidated` for the consolidator), harness, provider and model, so a report still says what it is when copied out of the tree. The agent index keeps names unique when a provider/model is configured more than once (e.g. to get several independent analyses from one model) and sits before the harness, so filenames sort in agent order once there is more than one harness. Provider and model are sanitized like the slug but keep their case.
- **Metadata is YAML front matter written by the orchestrator**, never by the model: it gives tools structured provenance, stays readable in the terminal, and is how reports are identified, so nothing parses filenames. Timestamps are unquoted ISO 8601, so they parse directly as `Time` objects. Beyond the `provider` and `model` every report needs to be recognized, `--consolidate` needs the analysts' `prompt_file`, `config_file`, `run_stamp` and `query`, and their `agent_index` to tell which configured agents have no report.

The optional consolidator (a top-level `consolidator:` provider and model
in the config, §5) runs after all agents finish, as one more pi run with
the same tools and scaffolding. Its prompt is
`lib/agent_council/templates/consolidate_prompt.md` followed by the
original prompt, every analyst report labeled with its source, and the
agents without a report with their failure reasons (with `--consolidate`,
which can't know them, a note that the reason wasn't recorded). A consolidation
failure is reported but does not change a normal run's exit status
(`--consolidate`'s exit status is the consolidation's).

The orchestrator already knows model identity, so analysts aren't asked to report it; the consolidator gets each report's source label from the orchestrator.

---

## 13. Pi Output Parsing

agent-council reads pi's JSONL event stream (`--mode json`) rather than scraping human-oriented terminal output. Pi documents `message_end` as the authoritative final message of a turn, so the final response is the text of the last assistant `message_end` event that has text (a trailing text-less message doesn't hide an earlier report). Pi exits 0 even when the provider rejects the request, so a non-blank `errorMessage`, or a `stopReason` of `length`, `aborted` or `error` (output cut off, cancelled, or failed without an `errorMessage`), counts as a failure. Only the last assistant message and the one that would be saved are checked, so an error in a turn that a later turn recovered from is not a failure. Failures are reported, not saved as reports.

Parsing extracts only that; there is no generic Pi protocol library.

The parser and the pi CLI invocation for runs live in `AgentCouncil::Harnesses::PiHarness`
(`lib/agent_council/harnesses/pi_harness.rb`), the single home of harness-
specific behavior for runs (the separate `pi-models` helper also talks to
pi); `exe/agent-council` stays harness-agnostic so a second
harness can be added as another such module under `AgentCouncil::Harnesses`.

---

## 14. Output Directory

Reports go into `agent-council-reports/` under the current working
directory — i.e. the repository being analyzed — so the tool can be run
from any project:

```text
agent-council-reports/
```

The name says which tool wrote the directory, since it lands in someone
else's tree. `-o` / `--output-dir` (or an `AGENT_COUNCIL_OPTS` default)
replaces only this base directory; everything beneath it is the same. The
README's [Running](README.md#running) section has the rules. An
`AGENT_COUNCIL_OPTS` default is ignored by `--consolidate`, rather than
rejected like an explicit `--output-dir`, since it is not specific to the
run.

Each run writes a timestamped, day-bucketed run directory (see §12), so
repeated runs accumulate without overwriting; beyond `--consolidate` (§6),
no run management is implemented.

---

## 15. Basic Failure Handling

Failure handling is simple. If a Pi invocation fails, agent-council:

- prints a useful error;
- writes no report for it;
- lets the other model runs finish.

One failed model doesn't discard successful results from others. The
README's [What you get](README.md#what-you-get) section shows how
failures are reported.

There are no retries of agent-council's own (pi may retry transient provider failures), error taxonomies, fallback models, semantic report validation, or separate process/report status systems.

---

## 16. Repository Layout

```text
README.md
DESIGN.md
RELEASE_NOTES.md
LICENSE.txt
REVIEW_NOTES.md          # settled review findings; not shipped in the gem
CONTRIBUTING.md          # contribution process; not shipped in the gem
code-review-agents.md    # sample code-review ensemble recommendation
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
    worker_pool.rb       # worker threads, agent processes and Ctrl-C handling
    harnesses/
      pi_harness.rb      # pi-specific behavior (AgentCouncil::Harnesses::PiHarness)
    templates/           # runtime data files (resolved via __dir__, shipped in the gem)
      consolidate_prompt.md  # instructions template for the consolidator
      analyst_format.md      # report-format addendum for analysts
spec/                    # RSpec; not shipped in the gem

examples/                # pure, non-runtime samples (prompts/ and configs/ ship in the gem)
  prompts/
    smoke-test_prompt.md
    code-base-state_prompt.md
    project-name-prompt.md
    recommend-model-ensemble-prompt.md
    review-latest-commit-prompt.md
    review-docs-prompt.md
  configs/
    single.yml
    consolidated.yml
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

agent-council is at an early stage (0.x), so it does only what its core job needs. Features we hope to add include support for more harnesses than Pi (such as Claude Code and Codex) and token and cost tracking. A missing feature is usually just not built yet.

`REVIEW_NOTES.md` separately tracks review findings that were considered and don't need to be re-raised: accepted risks and non-issues.

---

## 19. Design Rule

Every proposed feature should pass this test:

> Is this necessary to run the same prompt through multiple Pi-accessible models and save their answers?

If not, defer it.
