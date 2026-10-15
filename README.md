# agent-council

A small experiment: run the **same analytical prompt** through several
models using the [Pi](https://github.com/earendil-works/pi-mono) coding-agent
harness, and save each model's final response as a separate Markdown report.

Goal: collect genuinely different viewpoints on the same question from
multiple harness/model instances. This experiment is the short-term step —
does varying only the models through one harness (Pi) already produce
enough useful diversity? See [`DESIGN.md`](DESIGN.md) for the rationale and explicit
non-goals.

## Prerequisites

- Ruby 3.2 or later (standard library only for the tool itself; CI tests
  3.2, 3.3, 3.4 and 4.0)
- The `pi` CLI installed (`pi --version`; tested with pi 1.1.0)
- Credentials for at least one provider (several give more diverse
  viewpoints), configured through pi itself
  (`/login` in interactive pi, or provider API-key env vars)

## Installation

Install the gem to make the `agent-council` command available on your
RubyGems executable path:

```bash
gem install agent-council
agent-council -h
```

If you manage Ruby dependencies with Bundler, add the gem to your application's
Gemfile and run its commands through Bundler:

```bash
bundle add agent-council
bundle exec agent-council -h
```

The gem does not install a config file. Create `agent-council.yml` in the
directory you will analyze, or `~/.agent-council.yml` in your home directory,
and put your model configuration there. When no config path is passed, the
command checks the current working directory first, then the home config. See
[Discovering and configuring models](#discovering-and-configuring-models) for
the config format; a minimal config looks like this:

```yaml
# agent-council.yml
agents:
  - provider: opencode-go
    model: kimi-k2.7-code
consolidator:            # optional; omit to skip consolidation
  provider: opencode-go
  model: kimi-k2.7-code
```

More samples are in [`examples/configs/`](examples/configs/), which is
included in the installed gem.

To work on agent-council itself, you can run `./exe/agent-council` from a source
checkout instead. Note that Pi analyzes its working directory, so running it
from the checkout analyzes agent-council itself; to analyze another project,
`cd` there and give the full path to the checkout's `exe/agent-council`.

### Finding the installed documentation and examples

The installed gem contains this README, [`DESIGN.md`](DESIGN.md),
[`code-review-agents.md`](code-review-agents.md), `RELEASE_NOTES.md`, and the
sample prompts and configs under `examples/`, all matching the installed
version. The help output shows where they are for the copy of
`agent-council` you are actually running:

```bash
agent-council -h               # see "Documentation (Local)" and "Examples (Local)"
bundle exec agent-council -h   # in a Bundler project: the version in Gemfile.lock
```

To get the gem's directory in a shell variable:

```bash
AC_HOME=$(ruby -e 'print Gem::Specification.find_by_name("agent-council").full_gem_path')
```

If several versions are installed, this finds the newest — the same one a
plain `agent-council` command runs. In a Bundler project, prefix it with
`bundle exec` (or use `bundle info agent-council --path`) to get the version
Bundler selects.

## Discovering and configuring models

```bash
pi --list-models                 # all provider/model pairs in the catalog
pi --list-models kimi            # fuzzy search
pi auth check --provider openai  # is this provider authenticated?
```

Edit the config to choose the ensemble. The config is the optional second
argument; if omitted, `./agent-council.yml` in the current directory is used
(only the current directory is checked), else `~/.agent-council.yml` in your
home directory (hidden, so it doesn't clutter `ls`). It is an error if
none of these exists. Start from the minimal config above or a sample in
[`examples/configs/`](examples/configs/). Each entry becomes one
`pi --provider <provider> --model <model>` invocation. No Ruby changes are
needed to add, remove, or swap models.

For a recommended code-review ensemble, see
[`code-review-agents.md`](code-review-agents.md).

An optional top-level `consolidator:` entry (provider + model, same
shape as an agent) runs after all agents finish: that model receives the
original prompt plus all of the run's reports — each labeled with its
source model — plus the instructions in
`lib/agent_council/templates/consolidate_prompt.md` (edit
this file in a source checkout to tune the consolidation), and writes a
`<stamp>_<slug>_consolidated_pi_<provider>_<model>.md` report into the
same run dir. Remove the key to skip consolidation. A consolidation
failure is reported but does not affect the run's exit status.

To consolidate a finished run again — say its consolidation failed, or
you want another model's synthesis — pass its run dir:

```bash
agent-council --consolidate reports/2026-09-03/09-14-02
```

This runs only the consolidator, over the reports already in that run's
`answers/`, and writes its report into the same run dir. Run it from the
analyzed project's directory, as for a normal run: the consolidator
checks the reports' claims against the current directory. The prompt and
config are the run's own copies; the consolidator is the one in the
config copy, so edit that copy to try a different model. It won't
overwrite an existing report from the same consolidator (delete that
file to redo it); reports from different consolidators are kept side by
side, so you can compare their syntheses. Exit status is 0 only if the
consolidation succeeded. The consolidation instructions are the
installed template's, which may have changed since the run. Runs made by
versions without `--consolidate` can't be consolidated this way.

## Running

```bash
cd /path/to/the/repo/you/want/analyzed
agent-council /path/to/prompt.md
```

Agent Council has no target-directory option: Pi analyzes its **own working
directory**, which is the directory you run `agent-council` from. Run it from
the project you want analyzed; the prompt and config files can live anywhere.
Reports land in `./reports` under that working directory — each analyzed
project gets its own reports tree (you'll likely
want `reports/` in that project's `.gitignore`). If that directory has an
`untracked/` subdirectory, reports go in `untracked/reports` instead.

```bash
agent-council my-analysis-prompt.md                    # requires ./agent-council.yml or ~/.agent-council.yml
agent-council my-analysis-prompt.md other-config.yml  # alternate config
agent-council -h                                       # usage and options
```

(Paths are resolved from the working directory, including the default
`./agent-council.yml`; `~` is your home directory.)

Your first run needs only a prompt file and a config (see
[Installation](#installation)):

```bash
cd /path/to/the/repo/you/want/analyzed
echo 'In one paragraph, what does this project do?' > ~/what-is-this-prompt.md
agent-council ~/what-is-this-prompt.md
```

[`examples/`](examples/) holds sample prompts and configs — pure samples, not
used at runtime. `examples/prompts/` and `examples/configs/` are included in
the installed gem. The commands below use `$AC_HOME`, the installed gem's
directory (see [Finding the installed documentation and
examples](#finding-the-installed-documentation-and-examples)); in a source
checkout, set `AC_HOME` to the checkout's path. They still analyze your
current directory, and the sample configs name specific providers and
models — copy and edit one if yours differ.

- `examples/prompts/code-base-state_prompt.md` — a real codebase-analysis
  prompt; with `examples/configs/consolidated.yml` this is the full
  ensemble:

```bash
agent-council "$AC_HOME/examples/prompts/code-base-state_prompt.md" "$AC_HOME/examples/configs/consolidated.yml"
```

- `examples/prompts/smoke-test_prompt.md` +
  `examples/configs/single.yml` — a tiny, cheap prompt (one multiplication
  question — enough to prove a real answer came back) and a one-model
  config, for verifying your setup in seconds:

```bash
agent-council "$AC_HOME/examples/prompts/smoke-test_prompt.md" "$AC_HOME/examples/configs/single.yml"
```

- `examples/prompts/project-name-prompt.md` + any one-model config —
  a small creative-writing prompt useful for spotting prompt-sensitivity
  differences across models.
- `examples/prompts/recommend-model-ensemble-prompt.md` — a reusable prompt
  for recommending a provider-diverse model ensemble for a task; its sample
  code-review recommendation is in
  [`examples/results/recommend-model-ensemble-code-review.md`](examples/results/recommend-model-ensemble-code-review.md)
  (generated output, in the source repository only — not in the gem).
- `examples/prompts/review-latest-commit-prompt.md` — a code-review prompt
  for the latest commit (plus any uncommitted changes); run it from the
  repository under review with a multi-model config.

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
        2026-09-02-16-21-43_codebase-review_01_pi_opencode-go_glm-5.3.md
        2026-09-02-16-21-43_codebase-review_02_pi_opencode-go_kimi-k3.md
        2026-09-02-16-21-43_codebase-review_03_pi_openai_gpt-6.1-sol.md
        2026-09-02-16-21-43_codebase-review_04_pi_cursor_claude-sonnet-5-5-high.md
      2026-09-02-16-21-43_codebase-review_consolidated_pi_opencode-go_glm-5.3.md  # if consolidator configured
    18-05-11/
      ...
  2026-09-03/
    09-14-02/
      ...
```

- **Run dir name**: `hh-mm-ss` inside a `yyyy-mm-dd` day bucket (local
  time, second resolution). Pure time, nothing else — except that if that
  name is already taken (two runs started in the same second, or local
  time repeating when clocks fall back or are set back), the new run gets
  `hh-mm-ss-2`, `-3`, ... instead, so each run has its own directory.
- **Report filenames** carry everything else:
  `<yyyy-mm-dd>-<hh-mm-ss>_<query-slug>_<agent-number>_pi_<provider>_<model>.md`,
  so a report stays self-describing when you copy or attach it outside the
  tree; `<hh-mm-ss>` includes the run dir's suffix, if any.
  `<agent-number>` is the agent's 1-based position in the config's
  `agents` list (`01`, `02`, ...) — it gives every report a stable, unique
  handle even if the same provider/model is configured more than once (e.g.
  to spread load across a rate-limited subscription), and it sits before
  the harness so filenames still sort in agent order once more than one
  harness is in play. The query slug comes from the prompt file name, with
  either `-prompt` or `_prompt` suffix stripped (`codebase-review-prompt.md`
  and `codebase-review_prompt.md` both become `codebase-review`).
- **Day buckets** keep `reports/` itself navigable when you have hundreds
  of runs.
- Each report file begins with a small **YAML front matter** block — `role`
  (`analyst` or `consolidator`), `timestamp` (unquoted ISO 8601), `query`,
  `harness`, `provider`, `model`, `duration` (`HH:MM:SS`), `prompt_file`
  and `config_file` (the names of the run dir's input copies) and
  `run_stamp` (the report filenames' date-time prefix, with the run dir's
  suffix, if any), the last three used by `--consolidate`; for analyst
  reports, `agent_index`; and for consolidated reports, `sources` (the
  analyst labels that were synthesized), `source_durations`, and
  `consolidated_at` (when the consolidation ran; later than `timestamp`,
  the run's start, when done by `--consolidate`) — written by the
  orchestrator (never by the model). It gives tools structured provenance, stays
  readable in the terminal, and is how reports are identified:
  consolidation labels come from front matter, not filename parsing, so
  stray `.md` files in `answers/` are ignored. Below it is the model's
  verbatim final message. Unquoted ISO timestamps parse cleanly as `Time`
  objects.
- The copied prompt and config make every run reproducible after the fact.
  (An alternate config keeps its own filename, e.g. `single.yml`. The
  prompt, the config and `analyst_format.md` must therefore have
  different file names; a run that would copy two under one name stops
  before starting.)
  The orchestrator itself is deliberately not copied: it is versioned in
  git and may grow into multiple files.

Each run prints its run directory as it starts
(`Run dir: reports/2026-09-03/09-14-02`), so you can open it while agents
are still working, or after a Ctrl-C. Other access patterns:

```bash
ls -d reports/*/* | tail -1                # last run by name: usually the newest
ls reports/$(date +%F)/                    # today's runs
ls reports/*/*/answers/*codebase-review*   # every report for one question, all runs
```

The summary printed at the end shows which models succeeded and how long
each took (`HH:MM:SS`); the consolidator's duration is printed when it
finishes. One model's failure does not affect the others. Exit status is
0 only if every agent succeeded. Ctrl-C (SIGINT), SIGTERM, SIGHUP or
SIGQUIT stops the run, keeping reports already written. agent-council
sends each running agent, including the consolidator, SIGTERM (pi then
also stops any commands it started), gives them a shared 5-second grace
period to exit, and kills any still running. It then dies by that signal,
as a shell expects (so, e.g., Ctrl-C also stops a loop running it); for
SIGQUIT it exits with status 131 instead of dumping core. A second SIGINT,
SIGTERM or SIGQUIT kills the agents at once; further SIGHUPs, which a
closing terminal can send in pairs, are ignored. A killed agent can't stop
the commands it started, so those may keep running. A signal agent-council
was started ignoring (e.g. SIGHUP under `nohup`) stays ignored. On POSIX
systems agents run in process groups of their own, so Ctrl-Z suspends only
agent-council, not the agents. (Windows is untested; it has neither
process groups nor SIGTERM, so there agents may only be killed, after the
grace period.)
Output paths are printed relative to the current working directory (e.g.
`reports/2026-09-04/21-39-01/answers`), regardless of where the tool was
invoked from — the tool runs in any project, so paths are always in
*your* tree.

## How it works (and what pi is told)

- All pi-specific knowledge — CLI invocation, the tool list and
  scaffolding, and event-stream parsing — is isolated in
  `lib/agent_council/harnesses/pi_harness.rb`
  (`AgentCouncil::Harnesses::PiHarness`); harness-agnostic orchestration
  lives in `lib/agent_council.rb` (`AgentCouncil`), which selects the
  harness via the single `HARNESS` constant. Worker threads, agent
  processes and Ctrl-C handling live in `lib/agent_council/worker_pool.rb`
  (`AgentCouncil::WorkerPool`). `exe/agent-council` is just the executable
  entry point. A future second harness would be
  another module under `AgentCouncil::Harnesses`.
- Every agent receives the **byte-identical contents of the prompt file**,
  piped to pi on stdin (pi merges piped stdin into the initial prompt).
  No roles, no per-model customization.
- Each agent runs as
  `pi -p --mode json --no-session --tools read,grep,find,ls,bash
   --provider P --model M --append-system-prompt <scaffolding>`.
- `--no-session` keeps runs independent: no conversation state leaks
  between ensemble members.
- `edit`/`write` tools are withheld; `bash` remains for investigation
  (`git log`, dependency inspection, ...). Withholding those two tools is
  the only enforced restriction: the rules below are instructions to the
  model, not a sandbox (see [Safety and privacy](#safety-and-privacy)). A
  fixed scaffolding text appended to the system prompt (identical for all
  agents except the scratch path) forbids modifying files, changing git
  state, and installing software. It also forbids running
  tests/builds/servers unless the prompt explicitly permits it — concurrent
  analysts share databases, ports, and tmp paths, so by default stateful
  commands are described in the report instead of executed. When a prompt
  permits them (as `examples/prompts/review-latest-commit-prompt.md` does),
  agents are still told to skip commands needing shared services (databases,
  servers, fixed ports, Docker).
- Each agent gets its own disposable temp directory (exposed via `TMPDIR`
  and named in the scaffolding), deleted after the run. After Ctrl-C, a
  directory can be left behind if its agent had to be killed.
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

## Safety and privacy

agent-council does not sandbox the agents. Before running it, know that:

- **Agents have a shell.** Each agent, the consolidator included, gets pi's
  `bash` tool, running as you, in the directory you run from, with your
  environment (including any API keys in it; agent-council only adds
  `TMPDIR`), your file permissions and your network access. Only the `edit`
  and `write` tools are withheld. The read-only rules described above are
  instructions in the system prompt, which a model can ignore or misapply.
- **The analyzed repository can steer the agents.** Agents read the
  repository's files, and pi loads its trusted project resources
  (`AGENTS.md`, skills, extensions), so text in the repository can try to
  direct what the agents run (prompt injection). Prompts that permit tests,
  such as `examples/prompts/review-latest-commit-prompt.md`, run the
  project's own code.
- **Your code goes to every configured provider.** Whatever an agent reads,
  and the output of whatever it runs, is sent to that agent's provider. The
  consolidator's provider receives the prompt and all reports, plus
  anything the consolidator itself reads or runs. Check those providers'
  data policies before analyzing private code.
- **Reports stay in the analyzed project.** They are written under
  `reports/` (or `untracked/reports/`) in the working directory; add that
  to the project's `.gitignore` if you don't want them committed.

Run agent-council only on repositories you trust, or inside a container, VM
or disposable checkout that holds no credentials you aren't willing to
expose.

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

## Limitations (deliberate)

No retries, no timeouts, no cost tracking, no ranking or scoring of reports
(beyond the optional consolidator's synthesis), no manifests or indexes —
the directory layout is the index. This is an experiment to answer one
question: is Pi-based model diversity worth building on? See
[`DESIGN.md`](DESIGN.md) §19–21.

## Development

In a source checkout, run `bin/setup` (which runs `bundle install`), then
`bundle exec rspec` for the unit tests (no model calls) and
`bundle exec rubocop` for lint; there, `./exe/agent-council` is equivalent
to the installed `agent-council`. To run both checks before each commit,
install the pre-commit hook in `hooks/`:

```bash
bin/setup-hooks
```

`bundle exec rake security` checks the bundle's gems (bundler-audit) and the
Ruby and RubyGems versions (ruby-audit) for known vulnerabilities; CI runs it
on pushes and pull requests to `main`, on demand, and weekly to catch new
advisories. (GitHub disables scheduled workflows in public repositories after
60 days without activity; re-enable the Security workflow from the Actions
tab.) If it reports a vulnerable gem, run `bundle update <gem>` and rerun the
audit and the tests; if a Gemfile constraint blocks the fixed version, raise
the constraint (CI resolves fresh, since `Gemfile.lock` isn't committed). A
ruby-audit finding means upgrading Ruby, or RubyGems with
`gem update --system`. The RuboCop versions are pinned in the Gemfile and
bumped deliberately. agent-council has no runtime dependencies, so findings
concern the development environment, not what users install.

## Occasional utility: `pi-models`

The gem also includes `pi-models`, a helper for listing models configured in
the `pi` CLI. It prints a table by default; `pi-models --json` emits JSON and
`pi-models --ids` prints `provider/id` values for shell use. It requires `pi`
to be installed and can be run directly after installing the gem.
