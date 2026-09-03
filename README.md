# multiagent-pi-experiment

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

Edit `ensemble.yml` to choose the ensemble. Each entry becomes one
`pi --provider <provider> --model <model>` invocation. No Ruby changes are
needed to add, remove, or swap models.

## Running

```bash
cd /path/to/the/repo/you/want/analyzed
ruby /path/to/this/repo/ensemble.rb /path/to/prompt.md
```

Pi analyzes its **own working directory**, so run the script from the
repository under analysis. Reports always land in `reports/` inside *this*
repository (where `ensemble.rb` lives), not in the analyzed repo.

```bash
ruby ensemble.rb my-analysis-prompt.md                        # uses ./ensemble.yml
ruby ensemble.rb my-analysis-prompt.md other-config.yml       # alternate config
rspec                                                         # unit tests (no model calls)
```

`ensemble.rb` has a shebang and is executable, so `./ensemble.rb ...` (or an
absolute path) works identically to `ruby ensemble.rb ...`.

`examples/` holds plumbing-test material: `smoke-test_prompt.md` is a tiny,
cheap prompt (one multiplication question — enough to prove a real answer
came back), and `ensemble.smoke.yml` is a one-model config. Use them to
verify your setup end-to-end in seconds before a full run:

```bash
ruby ensemble.rb examples/smoke-test_prompt.md examples/ensemble.smoke.yml
```

**Prompt naming convention:** end prompt files in `_prompt.md`
(`code-base-state_prompt.md`, `security-review_prompt.md`). The file name
becomes the query slug in report filenames, with the `_prompt` suffix
stripped — so `code-base-state_prompt.md` yields the slug
`code-base-state`, not `code-base-state-prompt`.

## What you get

Each invocation creates one self-contained run directory, day-bucketed:

```text
reports/
  2026-09-02/
    16-21-43/
      codebase-review.md                                     # copy of the prompt, as asked
      ensemble.yml                                           # copy of the config used
      2026-09-02-16-21-43_codebase-review_pi_openai-codex_gpt-5.4.md
      2026-09-02-16-21-43_codebase-review_pi_github-copilot_claude-sonnet-5.md
      2026-09-02-16-21-43_codebase-review_pi_opencode-go_kimi-k2.6.md
      2026-09-02-16-21-43_codebase-review_pi_zai_glm-5.3.md
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
  `<yyyy-mm-dd>-<hh-mm-ss>_<query-slug>_pi_<provider>_<model>.md`, so a
  report stays self-describing when you copy or attach it outside the tree.
  The query slug comes from the prompt file name, with any conventional
  `_prompt` suffix stripped (`codebase-review_prompt.md` →
  `codebase-review`).
- **Day buckets** keep `reports/` itself navigable when you have hundreds
  of runs.
- **`reports/latest`** is a relative symlink to the newest run, so the
  common case is always `open reports/latest/`.
- Each report file contains exactly the final assistant message from that
  run — written by the Ruby program, never by the model.
- The copied prompt and config make every run reproducible after the fact.
  (An alternate config keeps its own filename, e.g. `ensemble.smoke.yml`.)
  The orchestrator itself is deliberately not copied: it is versioned in
  git and may grow into multiple files.

Access patterns:

```bash
open reports/latest/                      # newest run
ls reports/$(date +%F)/                   # today's runs
ls reports/*/*/*codebase-review*          # every report for one question, all runs
```

The summary printed at the end shows which models succeeded; one model's
failure does not affect the others. Exit status is 0 only if every agent
succeeded.

## How it works (and what pi is told)

- All pi-specific knowledge — CLI invocation, the read-only tool policy and
  scaffolding, and event-stream parsing — is isolated in `pi_harness.rb`
  (`PiHarness`). `ensemble.rb` is harness-agnostic orchestration and selects
  the harness via the single `HARNESS` constant; a future second harness
  would be another module shaped like `PiHarness`.
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
  `PiHarness.final_response`): the last `message_end` event with
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
