# Pre-Implementation Design — MVP

## 1. Goal

The long-term goal is to collect genuinely different viewpoints on the same question from multiple harness/model instances.

This repository is the short-term step: an experiment to validate whether varying only the models under a single harness (Pi) already produces sufficiently diverse and useful results, before harness diversity is added.

It is intentionally not yet a gem or general-purpose framework.

Build a small Ruby CLI that runs the **same prompt** through several AI model/provider combinations using the Pi coding-agent harness and saves each final response to a deterministic Markdown file.

The immediate objective is utility, not completeness.

We want to be able to run something like:

```bash
./exe/agent-council prompt.md
```

and quickly get independent reports from several models.

---

## 2. Why

Different models often produce materially different analyses of the same codebase or problem.

Typical prompts include:

- What is the best way to resolve this issue?
- Give me a comprehensive state-of-the-codebase analysis.
- Identify important codebase issues needing attention.
- What architectural or maintainability problems should we address?

We want each model to receive the same substantive prompt so that differences in results come from the models themselves.

The MVP does not attempt to rank, debate, or synthesize the responses.

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

We do not assign different roles such as critic, architect, or security reviewer.

The purpose is independent answers to the same question.

---

## 4. Initial Architecture

For the MVP, Pi is the only harness.

The Ruby program owns orchestration and invokes Pi once per configured provider/model combination.

```text
Ruby CLI
   |
   +-- Pi + model A
   +-- Pi + model B
   +-- Pi + model C
   +-- Pi + model D
```

This deliberately tests model diversity before we decide whether harness diversity is valuable enough to justify integrating native Claude Code, Codex, Cursor, OpenCode, or `oneharness`.

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
```

Exact provider and model identifiers must be verified against the installed Pi version.

They belong in configuration because available models and names change frequently.

---

## 6. CLI

Initial command:

```bash
./exe/agent-council prompt.md
```

The command should:

1. read configuration;
2. read the prompt;
3. launch all configured Pi model runs;
4. wait for them to complete;
5. save each successful result;
6. print a concise success/failure summary.

---

## 7. Parallel Execution

Agents should normally run concurrently.

Conceptually:

```ruby
threads = agents.map do |agent|
  Thread.new do
    run_agent(agent)
  end
end

threads.each(&:join)
```

The exact implementation can use Ruby threads or another comparably simple mechanism.

Do not introduce a job system, daemon, async framework, or workflow engine.

---

## 8. Prompt Identity

Every model must receive the same substantive prompt.

Do not:

- assign different roles;
- customize analytical instructions per model;
- ask models to identify themselves;
- add model-specific output instructions.

Execution metadata should remain outside the substantive prompt wherever practical.

---

## 9. Prompt Delivery

Large prompts should not be interpolated into shell command strings.

Prefer stdin or another Pi-supported mechanism suitable for large multiline prompts.

Prompts may contain:

- Markdown;
- source code;
- quotes;
- shell characters;
- Unicode;
- long analytical instructions.

Use proper subprocess argv/process APIs rather than shell interpolation.

---

## 10. Repository and System Safety

For this experiment, agents are analyzers, not modifiers.

Agents must not intentionally:

- modify, create, rename, or delete project source or configuration files;
- change Git state;
- install or remove software;
- modify user or system configuration;
- start persistent services;
- make other persistent changes to the machine.

Each agent must receive its **own dedicated disposable temporary directory**, unique to that agent run.

Agents may write freely within that directory.

Temporary files, caches, logs, generated output, and other scratch artifacts should be directed there whenever the relevant tool supports doing so.

Agents may run clearly read-only investigative commands, including:

- reading and searching files;
- listing directories;
- inspecting Git history and status;
- inspecting dependency and configuration information;
- other commands known not to modify project or shared state.

Agents **must not run test suites, builds, coverage tools, application servers, database tasks, or other commands that may create or modify shared state** while ensemble members are executing concurrently.

This restriction exists because such commands may collide through shared resources even when each agent has its own temporary directory. Examples include shared databases, Redis, fixed ports, Docker resources, hard-coded temporary paths, or other process-global state.

If running tests or another potentially stateful command would materially improve the analysis, the agent should say so in its report and describe what it would run and why, rather than running it.

If testing a proposed code change requires modifying project files, the agent should describe the proposed experiment rather than performing the modification.

---

## 11. Pi Context Behavior

Pi may automatically load project-specific context such as:

- `AGENTS.md`;
- project context files;
- skills;
- extensions;
- prompt templates.

For this experiment, useful real-world analysis matters more than establishing a laboratory benchmark.

Therefore Pi should generally behave as it normally would when analyzing a repository.

However:

- each model run must be independent;
- conversation/session state must not leak between runs;
- any context-related options deliberately enabled or disabled should be documented.

Do not build a configurable controlled-comparison mode yet.

---

## 12. Report Files

The models should not write their own report files.

Pi returns the final response to the Ruby process.

The Ruby program writes that text to a deterministic filename based on the provider and model it invoked.

Example:

```text
reports/
  2026-09-02/
    16-21-43/
      codebase-review.md            # copy of the prompt, as asked
      consolidated.yml              # copy of the config used
      answers/                      # analysts' reports
        2026-09-02-16-21-43_codebase-review_pi_anthropic_claude-x.md
        2026-09-02-16-21-43_codebase-review_pi_openai_gpt-x.md
        2026-09-02-16-21-43_codebase-review_pi_opencode-go_kimi-x.md
        2026-09-02-16-21-43_codebase-review_pi_zai_glm-x.md
      2026-09-02-16-21-43_codebase-review_consolidated_pi_zai_glm-x.md  # consolidator output, if configured
  latest -> 2026-09-02/16-21-43
```

Each run gets its own directory: day bucket / `hh-mm-ss`. Inputs (prompt
and config copies) sit at the run dir root; so does the consolidator's
report, when configured — only the analysts' reports go to `answers/`;
reports are identified by
where they live, and their provider/model metadata comes from YAML front
matter the orchestrator writes at the top of each file (the body below it
is the model's verbatim response). Report filenames still carry the
full timestamp, a slug of the prompt file name, harness, provider, and
model, so they stay self-describing when copied out of the tree. Prompt
files may end in `-prompt.md` or `_prompt.md`; either suffix is stripped from
the slug (`codebase-review-prompt.md` and `codebase-review_prompt.md` both
become `codebase-review`). Copies of the
prompt and the config make each run reproducible later (the orchestrator is
versioned in git and deliberately not copied). A relative `reports/latest`
symlink points at the newest run.

The front matter has keys: `role` (`analyst` or `consolidator`),
`timestamp` (unquoted ISO 8601), `query` (slug), `harness`, `provider`,
`model` — and, for consolidated reports, `sources: [...]` listing the
analyst labels that were synthesized. Unquoted ISO timestamps parse
directly as `Time` objects. Status printed to the user uses paths
relative to the current working directory, not absolute.

The program should sanitize provider/model identifiers sufficiently to make safe filenames.

The orchestrator already knows model identity, so the model should not be asked to report it.

---

## 13. Pi Output Parsing

If Pi provides structured JSON or JSONL output suitable for non-interactive execution, prefer it over scraping human-oriented terminal output.

Before implementing the parser, inspect the installed Pi version and documentation to determine:

- the current non-interactive invocation syntax;
- provider/model selection syntax;
- how prompts should be supplied;
- how structured output is framed;
- how to identify the final assistant response;
- relevant exit behavior.

Implement only enough parsing to reliably extract the final response.

Do not build a generic Pi protocol library.

The parser and the pi CLI invocation live in `AgentCouncil::Harnesses::PiHarness`
(`lib/agent_council/harnesses/pi_harness.rb`), the single home of harness-
specific behavior; `exe/agent-council` stays harness-agnostic so a second
harness can be added as another such module under `AgentCouncil::Harnesses`.

---

## 14. Output Directory

Reports go into `reports/` under the current working directory — i.e. the
repository being analyzed — so the tool can be run from any project:

```text
reports/
```

If the working directory contains an `untracked/` directory (a conventional
home for git-ignored scratch files), reports go into `untracked/reports/`
instead. The check is made at run time and only the base directory changes;
everything beneath it (day buckets, `latest` symlink) is the same.

Each run writes a timestamped, day-bucketed run directory (see §12), so
repeated runs accumulate without overwriting; no further run management is
implemented yet.

---

## 15. Basic Failure Handling

Failure handling should remain simple.

If a Pi invocation fails:

- print a useful error;
- do not create a misleading report;
- allow other model runs to finish.

Example:

```text
Running 4 models...

✓ anthropic / claude-x
✓ openai / gpt-x
✗ zai / glm-x
✓ opencode-go / kimi-x
```

One failed model must not discard successful results from others.

Do not implement retries, error taxonomies, fallback models, semantic report validation, or separate process/report status systems yet.

---

## 16. Repository Layout

Keep the experiment small.

```text
README.md
DESIGN.md
.gitignore
exe/
  agent-council          # executable entry point; all code lives in lib/
lib/
  agent_council.rb       # harness-agnostic orchestration (AgentCouncil)
  agent_council/
    harnesses/
      pi_harness.rb      # pi-specific behavior (AgentCouncil::Harnesses::PiHarness)
spec/
  agent_council_spec.rb       # RSpec; harness-agnostic logic
  agent_council/
    pi_harness_spec.rb        # RSpec; pi invocation + event-stream parsing

prompts/
  consolidate_prompt.md  # instructions template for the consolidator

examples/
  prompts/
    smoke-test_prompt.md
    code-base-state_prompt.md
    project-name-prompt.md
  configs/
    single.yml
    consolidated.yml

reports/                 # created on demand; gitignored
```

Do not create gem infrastructure yet. A flat `lib/` now holds the code;
do not introduce deeper namespaces (`lib/agent_council/services/...`) unless
the experiment actually grows enough to require them.

A clean, disposable 100–300 line Ruby implementation is preferable to a speculative framework.

---

## 17. Dependencies

Prefer the Ruby standard library for the tool itself (tests use RSpec).

Likely useful libraries include:

```ruby
yaml
json
open3
fileutils
tmpdir
```

Avoid adding gems unless they solve a meaningful problem that would otherwise require substantial code.

---

## 18. MVP Completion Criteria

The experiment is successful when we can:

1. configure several Pi provider/model combinations;
2. write one analytical prompt;
3. run one command;
4. execute the models concurrently;
5. give every model the same substantive prompt;
6. save one Markdown report per successful model;
7. see which model runs succeeded or failed;
8. use the reports for a real codebase-analysis question.

Example:

```bash
./exe/agent-council prompts/codebase-review.md
```

produces:

```text
reports/
  2026-09-02/
    16-21-43/
      codebase-review.md
      consolidated.yml
      2026-09-02-16-21-43_codebase-review_pi_anthropic_claude-x.md
      2026-09-02-16-21-43_codebase-review_pi_openai_gpt-x.md
      2026-09-02-16-21-43_codebase-review_pi_opencode-go_kimi-x.md
      2026-09-02-16-21-43_codebase-review_pi_zai_glm-x.md
```

That is the first useful product.

---

## 19. Explicitly Deferred

The following are not part of this MVP:

- `oneharness` integration;
- native Claude Code integration;
- native Codex integration;
- Cursor integration;
- native OpenCode integration;
- Gemini CLI integration;
- generalized runner abstraction;
- gem packaging;
- RubyGems publishing;
- report comparison UI;
- report scoring;
- report/process status taxonomy;
- manifests;
- prompt hashes;
- raw stdout/stderr archives;
- token and cost tracking;
- CLI-version recording;
- automatic retries;
- budget controls;
- authentication abstraction;
- worktree isolation;
- repository-state recording;
- run-history management;
- schema validation;
- controlled context modes;
- RubyLLM integration;
- web UI;
- persistent services or daemons.

These are possible later enhancements, not prerequisites.

---

## 20. What We Want to Learn

The experiment should answer:

> Does running the same codebase-analysis prompt through several different models under Pi produce sufficiently different and useful analyses to justify keeping this workflow?

After using it on real tasks, we can then ask:

> Does using different native harnesses such as Claude Code and Codex add enough value beyond Pi-based model diversity to justify a second execution layer?

Only then should we decide whether to integrate `oneharness` or turn the project into a gem.

---

## 21. Design Rule

For the MVP, every proposed feature should pass this test:

> Is this necessary to run the same prompt through multiple Pi-accessible models and save their answers?

If not, defer it.
