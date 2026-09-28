# agent-council

A small experiment: run the **same analytical prompt** through several
models using the [Pi](https://github.com/earendil-works/pi-mono) coding-agent
harness, and save each model's final response as a separate Markdown report.

Goal: collect genuinely different viewpoints on the same question from
multiple harness/model instances. This experiment is the short-term step —
does varying only the models through one harness (Pi) already produce
enough useful diversity? See `DESIGN.md` for the rationale and explicit
non-goals.

## Prerequisites

- Ruby (standard library only for the tool itself; developed on Ruby 4.0)
- RSpec for the tests (`gem install rspec`)
- The `pi` CLI installed (`pi --version`; developed against pi 0.84.4)
- Credentials for at least two providers, configured through pi itself
  (`/login` in interactive pi, or provider API-key env vars)

## Discovering and configuring models

```bash
pi --list-models                 # all provider/model pairs in the catalog
pi --list-models kimi            # fuzzy search
pi auth check --provider zai     # is this provider authenticated?
```

Edit the config to choose the ensemble. The config is the optional second
argument; if omitted, `./agent-council.yml` in the current directory is used
(only the current directory is checked), and it is an error if neither
exists. Start from a sample in `examples/configs/`. Each entry becomes one
`pi --provider <provider> --model <model>` invocation. No Ruby changes are
needed to add, remove, or swap models.

An optional top-level `consolidator:` entry (provider + model, same
shape as an agent) runs after all agents finish: that model receives the
original prompt plus all of the run's reports — each labeled with its
source model — plus the instructions in
`lib/agent_council/templates/consolidate_prompt.md` (edit
this file in a repo checkout to tune the consolidation), and writes a
`<stamp>_<slug>_consolidated_pi_<provider>_<model>.md` report into the
same run dir. Remove the key to skip consolidation. A consolidation
failure is reported but does not affect the run's exit status.

## Running

```bash
cd /path/to/the/repo/you/want/analyzed
/path/to/this/repo/exe/agent-council /path/to/prompt.md
```

Pi analyzes its **own working directory**, so run the script from the
repository under analysis. Reports land in `./reports` under that working
directory — each analyzed project gets its own reports tree (you'll likely
want `reports/` in that project's `.gitignore`). If that directory has an
`untracked/` subdirectory, reports go in `untracked/reports` instead.

```bash
./exe/agent-council my-analysis-prompt.md                    # requires ./agent-council.yml to exist
./exe/agent-council my-analysis-prompt.md other-config.yml  # alternate config
./exe/agent-council -h                                       # usage and options
rspec                                                        # unit tests (no model calls)
```

(Paths are resolved from the working directory, including the default
`./agent-council.yml`.)

`exe/agent-council` has a shebang and is executable, so `./exe/agent-council ...`
(or an absolute path) works identically to `ruby exe/agent-council ...`.

`examples/` holds sample prompts and configs — pure samples, not used at
runtime and not shipped in the gem:

- `examples/prompts/code-base-state_prompt.md` — a real codebase-analysis
  prompt; with `examples/configs/consolidated.yml` this is the full
  ensemble:

```bash
./exe/agent-council examples/prompts/code-base-state_prompt.md examples/configs/consolidated.yml
```

- `examples/prompts/smoke-test_prompt.md` +
  `examples/configs/single.yml` — a tiny, cheap prompt (one multiplication
  question — enough to prove a real answer came back) and a one-model
  config, for verifying your setup in seconds:

```bash
./exe/agent-council examples/prompts/smoke-test_prompt.md examples/configs/single.yml
```

- `examples/prompts/project-name-prompt.md` + any one-model config —
  a small creative-writing prompt useful for spotting prompt-sensitivity
  differences across models.

Prompt filenames may end in `-prompt.md` or `_prompt.md`. The file name
becomes the query slug in report filenames, with either suffix stripped — so
`code-base-state-prompt.md` and `code-base-state_prompt.md` both yield the
slug `code-base-state`.

## What you get

Each invocation creates one self-contained run directory, day-bucketed:

```text
reports/
  2026-09-02/
    16-21-43/
      codebase-review.md                                     # copy of the prompt, as asked
      analyst_format.md                                      # format addendum appended to the prompt
      consolidated.yml                                       # copy of the config used
      answers/                                               # analysts' reports
        2026-09-02-16-21-43_codebase-review_01_pi_openai-codex_gpt-5.4.md
        2026-09-02-16-21-43_codebase-review_02_pi_github-copilot_claude-sonnet-5.md
        2026-09-02-16-21-43_codebase-review_03_pi_opencode-go_kimi-k2.6.md
        2026-09-02-16-21-43_codebase-review_04_pi_zai_glm-5.3.md
      2026-09-02-16-21-43_codebase-review_consolidated_pi_zai_glm-5.3.md  # if consolidator configured
    18-05-11/
      ...
  2026-09-03/
    09-14-02/
      ...
  latest -> 2026-09-03/09-14-02
```

- **Run dir name**: `hh-mm-ss` inside a `yyyy-mm-dd` day bucket (local
  time, second resolution — runs never overwrite each other). Pure time,
  nothing else.
- **Report filenames** carry everything else:
  `<yyyy-mm-dd>-<hh-mm-ss>_<query-slug>_<agent-number>_pi_<provider>_<model>.md`,
  so a report stays self-describing when you copy or attach it outside the
  tree. `<agent-number>` is the agent's 1-based position in the config's
  `agents` list (`01`, `02`, ...) — it gives every report a stable, unique
  handle even if the same provider/model is configured more than once (e.g.
  to spread load across a rate-limited subscription), and it sits before
  the harness so filenames still sort in agent order once more than one
  harness is in play. The query slug comes from the prompt file name, with
  either `-prompt` or `_prompt` suffix stripped (`codebase-review-prompt.md`
  and `codebase-review_prompt.md` both become `codebase-review`).
- **Day buckets** keep `reports/` itself navigable when you have hundreds
  of runs.
- **`reports/latest`** is a relative symlink to the newest run, so the
  common case is always `open reports/latest/`.
- Each report file begins with a small **YAML front matter** block — `role`
  (`analyst` or `consolidator`), `timestamp` (unquoted ISO 8601), `query`,
  `harness`, `provider`, `model` (and, for consolidated reports, `sources`:
  the analyst labels that were synthesized) — written by the orchestrator
  (never by the model). It gives tools structured provenance, stays
  readable in the terminal, and is how reports are identified:
  consolidation labels come from front matter, not filename parsing, so
  stray `.md` files in `answers/` are ignored. Below it is the model's
  verbatim final message. Unquoted ISO timestamps parse cleanly as `Time`
  objects.
- The copied prompt and config make every run reproducible after the fact.
  (An alternate config keeps its own filename, e.g. `single.yml`.)
  The orchestrator itself is deliberately not copied: it is versioned in
  git and may grow into multiple files.

Access patterns:

```bash
open reports/latest/answers/               # newest run's analyst reports
ls reports/$(date +%F)/                    # today's runs
ls reports/*/*/answers/*codebase-review*   # every report for one question, all runs
```

The summary printed at the end shows which models succeeded; one model's
failure does not affect the others. Exit status is 0 only if every agent
succeeded. Output paths are printed relative to the current working
directory (e.g. `reports/2026-09-04/21-39-01/answers`), regardless of
where the tool was invoked from — the tool runs in any project, so paths
are always in *your* tree.

## How it works (and what pi is told)

- All pi-specific knowledge — CLI invocation, the read-only tool policy and
  scaffolding, and event-stream parsing — is isolated in
  `lib/agent_council/harnesses/pi_harness.rb`
  (`AgentCouncil::Harnesses::PiHarness`); harness-agnostic orchestration
  lives in `lib/agent_council.rb` (`AgentCouncil`), which selects the
  harness via the single `HARNESS` constant. `exe/agent-council` is
  just the executable entry point. A future second harness would be
  another module under `AgentCouncil::Harnesses`.
- Every agent receives the **byte-identical contents of the prompt file**,
  piped to pi on stdin (pi merges piped stdin into the initial prompt).
  No roles, no per-model customization.
- Each agent runs as
  `pi -p --mode json --no-session --tools read,grep,find,ls,bash
   --provider P --model M --append-system-prompt <scaffolding>`.
- `--no-session` keeps runs independent: no conversation state leaks
  between ensemble members.
- `edit`/`write` tools are withheld; `bash` remains for read-only
  investigation (`git log`, dependency inspection, ...). A fixed scaffolding
  text appended to the system prompt (identical for all agents except the
  scratch path) forbids modifying files, changing git state, installing
  software, and running tests/builds/servers — concurrent analysts share
  databases, ports, and tmp paths, so stateful commands are described in
  the report instead of executed.
- Each agent gets its own disposable temp directory (exposed via `TMPDIR`
  and named in the scaffolding), deleted after the run.
- Otherwise pi behaves normally: `AGENTS.md`, skills, extensions, and prompt
  templates from the analyzed repo load as usual. (In non-interactive modes
  pi never shows a project-trust prompt; untrusted project-local resources
  are ignored per pi's security model.)
- The final response is parsed from pi's JSONL event stream (by
  `AgentCouncil::Harnesses::PiHarness.final_response`): the last `message_end` event with
  `role: "assistant"` — pi documents `message_end` as the authoritative
  final message of a turn. Note that pi exits 0 even
  when the provider rejects the request (e.g. Copilot's
  `model_not_available_for_integrator`); such failures are detected via the
  assistant message's `errorMessage` and reported, not saved as reports.

## Authentication caveats

Pi resolves credentials in this order:

1. `--api-key` flag (this program never passes one)
2. `auth.json` entry — **this is where OAuth subscription tokens live**
3. Environment variable (e.g. `OPENAI_API_KEY`, `ZAI_API_KEY`)
4. Custom provider keys from `models.json`

Because `auth.json` beats environment variables, a stray `OPENAI_API_KEY`
in your shell will **not** silently override a subscription login stored by
pi — the reverse of what many tools do. Use `pi auth check --provider <name>`
to see which credential pi will actually use (`authType: oauth` vs
`api_key`).

Verified on this machine (pi 0.84.4): `openai-codex` and `github-copilot`
are OAuth/subscription-backed; `opencode-go` and `zai` use API keys.
`anthropic` is not configured (Claude is reachable via `github-copilot`),
and `cursor` appears in the model catalog but the provider is not
installed/authenticated (`provider_not_found`).

## Limitations (deliberate)

No retries, no timeouts, no cost tracking, no synthesis or comparison of
reports, no manifests or indexes — the directory layout is the index. This
is
an experiment to answer one question: is Pi-based model diversity worth
building on? See `DESIGN.md` §19–21.
