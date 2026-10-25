# agent-council

Get a second opinion, and a third and a fourth, with one command:
agent-council runs the **same analytical prompt** through several models
using the [Pi](https://github.com/earendil-works/pi) coding-agent harness,
saves each model's final response as a separate Markdown report, and can
then have a **consolidator** model synthesize those reports into a single
one.

Why use it:

- **Catch what one model misses.** Different models notice different
  problems and weigh trade-offs differently; asking several surfaces
  blind spots that no single answer reveals.
- **Get one report to read, not five.** The optional consolidator reads
  every analyst report, checks their claims against your project where it
  can, and writes a synthesis, so you can see where the models agree and
  where they differ.
- **Compare models on your own work.** Each model's report is kept
  side by side, labeled with its source, for the same prompt and
  codebase.
- **Repeatable and cheap to set up.** A prompt file and a short YAML
  config are all a run needs; every run's reports, prompt, and config
  are saved together in a timestamped directory.

The project is at an early stage; support for more harnesses than Pi is
among the [planned features](DESIGN.md#18-status-and-future-work). See
[`DESIGN.md`](DESIGN.md) for the rationale.

> **Between releases**, the documentation in the repository describes the
> next release, not the latest published one, so it may cover features
> (and a version) that are not yet in a released gem. The documentation
> installed with the gem matches the installed version.

## Quick start

A first run from scratch, using two models and a consolidator that
synthesizes their reports. The sections after this one cover each step
in detail.

1. **Install the prerequisites:** Ruby 3.2+ (or JRuby 10+) and the
   [`pi` CLI](https://github.com/earendil-works/pi) (`pi --version`). See
   [Prerequisites](#prerequisites).
2. **Set up credentials for at least one provider in pi** (see
   [pi's documentation][pi-docs]), then list the models available to pi
   (a listed model can still be one your plan doesn't include). Two
   different providers give more diverse viewpoints, but two models from
   one provider work too:

   ```bash
   pi --list-models
   ```

3. **Install the gem:**

   ```bash
   gem install agent-council
   ```

4. **Go to the project you want analyzed:**

   ```bash
   cd /path/to/the/project/you/want/analyzed
   ```

5. **Write a config** named `agent-council.yml` there, replacing the
   placeholders with providers and models from step 2 (copy its
   `provider` and `model` columns as they are). The
   `consolidator` can be any model, including one of the agents:

   ```yaml
   # agent-council.yml
   agents:
     - provider: <provider-1>
       model: <model-1>
     - provider: <provider-2>
       model: <model-2>
   consolidator:
     provider: <provider-1>
     model: <model-1>
   ```

6. **Write a prompt and run it** from that same directory (the prompt
   file can live anywhere):

   ```bash
   echo 'In one paragraph, what does this project do?' > ~/what-is-this-prompt.md
   agent-council ~/what-is-this-prompt.md
   ```

   This calls each configured model at your providers' usual rates. Any
   files an agent reads, and the output of any commands it runs, go to
   that agent's provider; see [Safety and privacy](#safety-and-privacy).

Each model's answer is saved as a Markdown file under
`agent-council-reports/<yyyy-mm-dd>/<hh-mm-ss>/reviews/`, and the
consolidated report is written to the run directory itself; see
[What you get](#what-you-get). To add more models or change the
consolidator, see
[Discovering and configuring models](#discovering-and-configuring-models).

## Prerequisites

- Ruby 3.2 or later, or JRuby 10 or later (standard library only for the
  tool itself; CI tests 3.2, 3.3, 3.4, 4.0, JRuby 10.0 and the latest
  JRuby)
- The [`pi` CLI](https://github.com/earendil-works/pi) installed
  (`pi --version`; tested with pi 1.3.0 and 1.4.0)
- Credentials for at least one provider (several give more diverse
  viewpoints), configured through pi itself (see
  [pi's documentation][pi-docs])
- On Windows, WSL (e.g. Ubuntu): native Windows is not supported. Install
  and run Ruby, pi and agent-council inside WSL, from a WSL shell. Windows
  drives are reachable at `/mnt/c/...`, but file access there is much
  slower than in the Linux filesystem (e.g. `~/projects`). Set up pi's
  provider credentials inside WSL too; WSL doesn't share them with Windows.

## Installation

Install the gem to make the `agent-council` command available on your
RubyGems executable path:

```bash
gem install agent-council
agent-council -h
```

The gem creates no config for you; it ships samples in `examples/configs/`. See
[Discovering and configuring models](#discovering-and-configuring-models)
to write one. To work on agent-council itself, see
[Development](#development).

### Finding the installed documentation and examples

The installed gem contains this README, [`DESIGN.md`](DESIGN.md),
[`code-review-agents.md`](code-review-agents.md), `RELEASE_NOTES.md`, and the
sample prompts and configs under `examples/`, all matching the installed
version. The help output shows where they are for the copy of
`agent-council` you are actually running:

```bash
agent-council -h   # see "Documentation (Local)" and "Examples (Local)"
```

To get the gem's directory in a shell variable:

```bash
AC_HOME=$(ruby -e 'print Gem::Specification.find_by_name("agent-council", ">= 0.a").full_gem_path')
```

If several versions are installed, this finds the newest, prereleases
included: the same one a plain `agent-council` command runs.

In a Bundler project, prefix it with `bundle exec` (or use
`bundle info agent-council --path`) to get the version Bundler selects.

## Discovering and configuring models

```bash
pi --list-models                 # models of the providers you have credentials for
pi --list-models kimi            # fuzzy search
```

`pi --list-models` lists only the models of providers pi has
credentials for, not its whole catalog, so a provider missing from it
may just lack credentials. A listed model can still be unusable, e.g.
one your plan doesn't include. Credentials, and which one pi uses when
a provider has several, are pi's business; see
[pi's documentation][pi-docs].

Edit the config to choose the ensemble. The config is the optional second
argument; if omitted, `./agent-council.yml` in the current directory is used
(parent directories are not searched), else `~/.agent-council.yml` in your
home directory. It is an error if neither exists. Each entry becomes one
pi run with that `--provider` and `--model` (see
[How it works](#how-it-works-and-what-pi-is-told) for the full command), so no Ruby changes
are needed to add, remove, or swap models. A minimal config (replace the
provider and model with ones you have credentials for):

```yaml
# agent-council.yml
agents:
  - provider: opencode-go
    model: kimi-k2.7-code
consolidator:            # optional; omit to skip consolidation
  provider: opencode-go
  model: kimi-k2.7-code
```

The config must be a YAML mapping with a non-empty `agents` list. Each
agent, and the consolidator, needs string `provider` and `model` values
(quote any value YAML would read as something else, such as a number,
a date or `yes`); other keys are ignored.

More samples are in [`examples/configs/`](examples/configs/), which is
included in the installed gem. [`pi-models`](#occasional-utility-pi-models)
also lists the available models, in forms suited to scripts.

For a recommended code-review ensemble, see
[`code-review-agents.md`](code-review-agents.md). It is Markdown, not a
config file: copy its YAML block into your config.

An optional top-level `consolidator:` entry (provider + model, same
shape as an agent) runs after all agents finish. That model receives:

- the original prompt;
- the analyst reports in `reviews/`, each labeled with its source model;
- a list of the agents without a report, with each one's failure reason
  (in a normal run);
- the instructions in `lib/agent_council/templates/consolidate_prompt.md`
  in the gem's directory (`$AC_HOME`; see
  [Finding the installed documentation and examples](#finding-the-installed-documentation-and-examples))
  or a source checkout, where you can edit it to tune the consolidation.

agent-council saves its response as a report in the run dir itself (see
[What you get](#what-you-get) for its name). Remove the key to skip consolidation. To
consolidate a run that has already finished, see
[Consolidating a finished run](#consolidating-a-finished-run).

## Running

```bash
cd /path/to/the/repo/you/want/analyzed
agent-council /path/to/prompt.md
```

There is no option to choose the directory analyzed: Pi analyzes its **own
working directory**, which is the directory you run `agent-council` from. Run it from
the project you want analyzed; the prompt file can live anywhere, as can a
config given as an argument.
Reports land in `./agent-council-reports` under that working directory,
so each analyzed project gets its own reports tree. To put them
elsewhere, pass `-o DIR` / `--output-dir DIR`; a relative `DIR` is
resolved against the working directory. (An explicit `--output-dir` can't be
combined with `--consolidate`, which writes into the run dir it is given.)

```bash
agent-council my-analysis-prompt.md                   # requires ./agent-council.yml or ~/.agent-council.yml
agent-council my-analysis-prompt.md other-config.yml  # alternate config
agent-council -o tmp/council my-analysis-prompt.md    # reports under ./tmp/council
agent-council -h                                      # usage, options, and any AGENT_COUNCIL_OPTS value
agent-council -v                                      # version
agent-council --consolidate agent-council-reports/2026-09-03/09-14-02  # see Consolidating a finished run
```

`AGENT_COUNCIL_OPTS` can set default command-line options (currently only
`-o` / `--output-dir`), with explicit command-line arguments taking precedence:

```bash
export AGENT_COUNCIL_OPTS="--output-dir tmp/council"
agent-council my-analysis-prompt.md
agent-council --output-dir other-reports my-analysis-prompt.md  # overrides AGENT_COUNCIL_OPTS
```

It is only for default options, not positional arguments or one-shot
switches such as `--consolidate`, `--help`, or `--version`. The value is
split into words like a shell would, but agent-council doesn't expand
variables in it: `~` works, but a
literal `$HOME` stays literal. (In a double-quoted `export`, your shell
has already expanded it.) An `--output-dir` set there
is ignored by `--consolidate` (only an explicit one is an error). A
malformed value makes every command except `-h`/`--help` and `-v`/`--version` fail
(`--consolidate` included), with a message naming `AGENT_COUNCIL_OPTS`.

Relative paths are resolved from the working directory. agent-council
expands `~` itself only in `--output-dir`; in other paths, the shell
must expand it.

[`examples/`](examples/) holds sample prompts and configs — pure samples, not
used at runtime. `examples/prompts/` and `examples/configs/` are included in
the installed gem. The commands below use `$AC_HOME`, the installed gem's
directory (see [Finding the installed documentation and
examples](#finding-the-installed-documentation-and-examples)); in a source
checkout, set `AC_HOME` to the checkout's path and put its `exe/` on
your `PATH` (see [Development](#development)). They still analyze your
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
  config, for verifying your setup in seconds (the
  [report-format addendum](#how-it-works-and-what-pi-is-told) may wrap
  the number in a short report):

```bash
agent-council "$AC_HOME/examples/prompts/smoke-test_prompt.md" "$AC_HOME/examples/configs/single.yml"
```

- `examples/prompts/project-name-prompt.md` + `examples/configs/consolidated.yml` —
  a small creative-writing prompt useful for spotting prompt-sensitivity
  differences across models:

```bash
agent-council "$AC_HOME/examples/prompts/project-name-prompt.md" "$AC_HOME/examples/configs/consolidated.yml"
```

- `examples/prompts/recommend-model-ensemble-prompt.md` — a reusable prompt
  for recommending a provider-diverse model ensemble for a task (agents
  run [`pi-models`](#occasional-utility-pi-models), which is on your
  `PATH` once the gem is installed, and otherwise say they need a model
  list); its sample
  code-review recommendation is in
  [`examples/results/recommend-model-ensemble-code-review.md`](https://github.com/keithrbennett/agent-council/blob/main/examples/results/recommend-model-ensemble-code-review.md)
  (generated output, in the source repository only — not in the gem; it
  shares its title with, but is not, the curated
  [`code-review-agents.md`](code-review-agents.md)).
- `examples/prompts/review-latest-commit-prompt.md` — a code-review prompt
  for the latest commit (plus any uncommitted changes); run it from the
  repository under review with a multi-model config.
- `examples/prompts/review-docs-prompt.md` — a documentation review: checks
  the README, other Markdown files, help output, code comments and samples
  against the code for accuracy, completeness, consistency, first-run
  usability, and clarity (including duplication);
  run it from the repository whose docs you want reviewed.

### Stopping a run

Ctrl-C (or SIGTERM, SIGHUP or SIGQUIT) stops the run, keeping reports
already written:

- Running agents, the consolidator included, get SIGTERM (pi then also
  stops the commands it started) and a shared 5 seconds to exit before
  they are killed. A killed agent can't stop the commands it started, so
  those may keep running.
- A second SIGINT, SIGTERM or SIGQUIT kills them at once; further SIGHUPs
  are ignored.
- agent-council then dies by that signal, so a shell loop running it
  stops too; for SIGQUIT it exits with status 131 instead of dumping core.
- A signal agent-council was started ignoring (e.g. SIGHUP under `nohup`)
  stays ignored, and Ctrl-Z suspends agent-council but not the agents.
- Under JRuby, SIGQUIT is left to the JVM, which prints a thread dump,
  and doesn't stop the run.

[`DESIGN.md`](DESIGN.md) §7 explains why it works this way.

### Consolidating a finished run

To consolidate a finished run later — say its consolidation failed, it
had no consolidator, or you want another model's synthesis — pass its
run dir:

```bash
agent-council --consolidate agent-council-reports/2026-09-03/09-14-02
```

This runs only the consolidator, over the analyst reports in that run's
`reviews/`, and writes its report into the same run dir, named as in a
normal run, with the run's original `run_stamp` (its date and time, plus
any suffix). Exit status is 0 only if the consolidation succeeded.

- **Run it from the analyzed project's directory**, as for a normal run:
  the consolidator is asked to check the reports' claims against the
  current directory where it can.
- **The prompt and config are the run's own copies**, and the
  consolidator is the one in the config copy:
  - To try a different model, edit the copy's `consolidator:` (the copy
    then no longer records the run's original consolidator).
  - If the run had no consolidator, add a `consolidator:` entry to the
    copy first; otherwise `--consolidate` exits with an error.
  - Leave the copy's `agents:` exactly as they were (same order,
    providers and models): an agent counts as having no report when no
    report carries its number, provider and model.
- **The consolidation instructions are the current template's** (the
  installed gem's, or a checkout's own), which may have changed since
  the run.
- **Existing reports are kept.** A report from the same consolidator
  stops the run (delete that file to redo it); reports from different
  consolidators sit side by side, so you can compare their syntheses.
- **The run needs at least one analyst report written by
  agent-council**: the prompt and config copies are found through the
  reports' front matter (`prompt_file` and `config_file`, with
  `run_stamp` and `query` naming the consolidated report). A run where
  every analyst failed, or that was interrupted before any report was
  written, can't be consolidated.
- **Failure reasons aren't saved in the run dir**, so the consolidator
  is told only which configured agents have no report, with a note that
  the reason wasn't recorded.

## What you get

Each run creates one run directory, holding its inputs and reports,
day-bucketed
(`--consolidate` instead writes into the existing run directory it is
given):

```text
agent-council-reports/
  2026-09-02/
    16-21-43/
      codebase-review.md                                     # copy of the prompt (its own file name)
      analyst_format.md                                      # copy of the report-format addendum sent with the prompt
      consolidated.yml                                       # copy of the config used (its own file name)
      reviews/                                               # analysts' reports
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
  tree (a consolidated report has `consolidated` in place of
  `<agent-number>`); `<hh-mm-ss>` includes the run dir's suffix, if any,
  and `<provider>` and `<model>` are sanitized like the query slug below,
  but keep their case.
  `<agent-number>` is the agent's 1-based position in the config's
  `agents` list (`01`, `02`, ...), so every report has a unique name even
  if the same provider/model is configured more than once. The query slug
  is the prompt file name without its extension, minus any trailing
  `-prompt` or `_prompt` in any case (`codebase-review-prompt.md` and
  `codebase-review_prompt.md` both become `codebase-review`), lowercased, with each run of characters
  other than ASCII letters, digits, `.`, `_` and `-` replaced by `-` and
  leading or trailing `-` and `.` dropped (`My Prompt (draft).md` becomes
  `my-prompt-draft`); a name left empty becomes `prompt`.
- **Day buckets** keep the reports directory itself navigable when you have hundreds
  of runs.
- Each report file begins with a small **YAML front matter** block,
  written by the orchestrator (never by the model):
  - in every report: `role` (`analyst` or `consolidator`), `timestamp`
    (unquoted ISO 8601), `query` (the query slug), `harness`, `provider`, `model`,
    `duration` (`HH:MM:SS`), `prompt_file` and `config_file` (the names of
    the run dir's input copies), `config_source` (where the config was
    found, with `~` for the home directory; informational only) and
    `run_stamp` (the report filenames' date-time prefix, with the run
    dir's suffix, if any);
  - in analyst reports: `agent_index` (the agent number, as an integer);
  - in consolidated reports: `sources` (the analyst labels that were
    synthesized), `source_durations` (each source label's report duration), and `consolidated_at` (when the
    consolidation ran; with `--consolidate`, possibly long after
    `timestamp`, the run's start).

  `--consolidate` relies on the analysts' `prompt_file`, `config_file`,
  `run_stamp` and `query`, and on `agent_index` to tell which configured
  agents have no report. Reports are identified by their front matter,
  not by filename parsing, so `.md` files in `reviews/` without
  `provider` and `model` front matter are ignored.
- Below the front matter, the orchestrator adds a metadata table
  summarizing its main fields (for consolidated reports, under a
  `# Consolidated Report` title and a `### Prompt:` line), followed by the
  model's final message, minus any top-level `#` heading the message
  starts with.
- The copied prompt, config and report-format addendum keep an analyst
  run's inputs recoverable after the fact. The pi and agent-council
  versions, the scaffolding text appended to pi's system prompt and the
  consolidation template are not recorded.
- The prompt and config copies keep their own file names (e.g.
  `single.yml`), so the prompt, the config and `analyst_format.md` must
  have different file names, and none can be named `reviews`; a run that
  would break either rule stops before starting.

Each run starts by printing its config, prompt and run directory
(`Run Dir: agent-council-reports/2026-09-03/09-14-02`), then its agents
under `Review Agents (N):` and, if configured, `Consolidator Agent:`;
these labels also name the harness (e.g. `#2 pi / openai / gpt-6.1-sol`).
You can open the run dir while agents are still working, or after a
Ctrl-C (see [Stopping a run](#stopping-a-run)). Other access patterns:

```bash
ls -d agent-council-reports/*/* | tail -1                # last run by name: usually the newest
ls agent-council-reports/$(date +%F)/                    # today's runs
ls agent-council-reports/*/*/reviews/*codebase-review*   # every analyst report for one question, all runs
```

While the agents run, a `Review Progress:` section prints one line per
agent as it finishes: `✓` or `✗`, its duration, its label (e.g.
`#2 openai / gpt-6.1-sol`) and, for a failure, the reason.
When all reviews finish, a `Reviews` table shows which models succeeded,
how long each took (`HH:MM:SS`), and its report file (for a failure,
the reason in parentheses), followed by a
`--- Reviews complete (N/M succeeded) ---` line. With a consolidator,
the `Consolidation Report (in <run dir>):` heading (with
`--consolidate`, `(in <run dir>, from N review(s)):`) then prints while it
runs, its result row when it finishes, and finally `--- Consolidation
complete ---` (or `--- Consolidation error ---`). One model's failure
does not affect the others. Exit status is 0 only if every analyst
agent succeeded; the consolidator's result doesn't affect it.

Output paths are printed relative to the current working directory (e.g.
`agent-council-reports/2026-09-04/21-39-01/reviews`), not to where
agent-council is installed. Paths outside the working directory (such
as an `--output-dir` elsewhere) are printed absolute, as is a default
config's (`Config:  [default] /path/to/agent-council.yml`), to show
which default was picked up.

## How it works (and what pi is told)

- Every analyst agent receives the **same bytes**: the prompt file's
  contents (with one trailing newline removed), a blank line, and the
  report-format addendum
  (`lib/agent_council/templates/analyst_format.md`, copied into each run
  dir), piped to pi on stdin as the prompt. No roles, no per-model customization. The addendum asks for a
  Markdown report with `##` section headings, which can conflict with a
  prompt that asks for some other output form (the smoke-test prompt's
  "Reply with just the number, then one sentence explaining how you got
  it.", for example); models usually reconcile the two. (The
  consolidator gets its own prompt; see
  [Discovering and configuring models](#discovering-and-configuring-models).)
- Each agent runs as
  `pi -p --mode json --no-session --tools read,grep,find,ls,bash
   --provider P --model M --append-system-prompt <scaffolding>`.
- `--no-session` keeps runs independent: no conversation state leaks
  between ensemble members.
- `--tools` is an allowlist for pi's built-in, extension and custom
  tools: `bash` remains for investigation (`git log`, dependency
  inspection, ...), while file-editing tools and unlisted extension and
  custom tools are unavailable, as are MCP tools. The allowlist is the
  only enforced restriction (see [Safety and privacy](#safety-and-privacy)). A fixed
  scaffolding text appended to the system prompt (identical for all
  agents, the consolidator included, except the scratch path) tells agents
  not to modify project files, git state, software or configuration, or
  start persistent services (they get a scratch directory for temporary
  files), and
  not to run tests, builds or similar commands, which can collide between
  concurrent analysts, unless the prompt permits them (as
  `examples/prompts/review-latest-commit-prompt.md` does for tests and
  linters); where such a command isn't permitted but would help, the
  agent describes what it would run instead. The full text is
  `scaffold_text` in `lib/agent_council/harnesses/pi_harness.rb`;
  [`DESIGN.md`](DESIGN.md) §10 explains the rules.
- Each agent gets its own disposable temp directory (exposed via `TMPDIR`
  and named in the scaffolding), deleted after the run. After Ctrl-C, a
  directory can be left behind if a second signal stops agent-council at
  once, or if cleanup after a killed agent doesn't finish in time.
- Otherwise pi behaves normally: it loads context files such as
  `AGENTS.md` and `CLAUDE.md` as in any pi run, and the analyzed repo's
  `.pi` project resources only if pi already trusts the project
  (agent-council passes no `--approve`). See
  [pi's documentation][pi-docs] for what loads from where.
- The final response is read from pi's JSONL event stream. pi exits 0
  even when the provider rejects the request (e.g. Copilot's
  `model_not_available_for_integrator`) or the output is cut off;
  agent-council detects these in the event stream and reports them as
  failures, not reports. [`DESIGN.md`](DESIGN.md) §13 has the details.

## Safety and privacy

agent-council does not sandbox the agents. Before running it, know that:

- **Agents have a shell.** Each agent, the consolidator included, gets pi's
  `bash` tool, running as you, in the directory you run from, with your
  environment (including any API keys in it; agent-council only sets
  `TMPDIR`), your file permissions and your network access. Of pi's
  built-in tools, only `edit` and `write` (and the Windows-only
  `powershell`) are withheld. The read-only rules described above are
  instructions in the system prompt, which a model can ignore or misapply.
- **MCP servers still start.** agent-council doesn't pass `--no-mcp`,
  so pi starts or connects the MCP servers you have configured for every
  agent, as you. Their tools can't be called (tested with pi 1.4.0):
  the `--tools` allowlist names none of them, nor pi's `codemode` and
  `tool_search` tools, which reach them indirectly. A server that does
  something merely by starting still does it.
- **The analyzed repository can steer the agents.** Agents read the
  repository's files, and pi loads its context files (such as
  `AGENTS.md`) and, if the project is trusted, its `.pi` resources, so
  text in the repository can try to direct what the agents run (prompt
  injection). Prompts that permit tests,
  such as `examples/prompts/review-latest-commit-prompt.md`, run the
  project's own code.
- **Your code goes to every configured provider.** Whatever an agent reads,
  and the output of whatever it runs, is sent to that agent's provider. The
  consolidator's provider receives the prompt and all reports, plus
  anything the consolidator itself reads or runs. Check those providers'
  data policies before analyzing private code.
- **Reports stay in the analyzed project by default.** They are written
  under `agent-council-reports/` in the working directory, unless you give
  an `--output-dir`; add that directory to the project's `.gitignore` if
  you don't want them committed.

Run agent-council only on repositories you trust, or inside a container, VM
or disposable checkout that holds no credentials you aren't willing to
expose.

## Limitations (deliberate)

No retries or timeouts of agent-council's own (pi itself may retry
transient provider failures), no ranking
or scoring of reports
(beyond the optional consolidator's synthesis), no manifests or indexes —
the directory layout is the index. See [`DESIGN.md`](DESIGN.md) §18–19.

## Stability

This is a 0.x release. The config format, command-line interface, run
directory layout and report front matter may change incompatibly before 1.0.

## Development

In a git checkout (the gemspec lists files with `git ls-files`),
`./exe/agent-council` and `./exe/pi-models` are equivalent to the installed `agent-council` and
`pi-models`. Agents analyze the working directory, so running
`./exe/agent-council` from the checkout analyzes agent-council itself; to
analyze another project, `cd` there and run the checkout's executable by
its full path. Sample prompts such as `recommend-model-ensemble-prompt.md`
expect `pi-models` on your `PATH`; to use them from a checkout, add its
`exe/` directory (`export PATH="/path/to/agent-council/exe:$PATH"`).

Setup, tests, lint, the pre-commit hook and the security audit are
described in [`CONTRIBUTING.md`](https://github.com/keithrbennett/agent-council/blob/main/CONTRIBUTING.md)
in the source repository. Before submitting a pull request, open an
issue and wait for explicit approval; `CONTRIBUTING.md` describes the
process.

## Occasional utility: `pi-models`

The gem also includes `pi-models`, a helper for listing the provider/model
pairs available to the `pi` CLI — those of the providers you have set up
credentials for (see
[Discovering and configuring models](#discovering-and-configuring-models)).
It prints a table, JSON, or one `provider/id` per line for shell use
(`pi-models -h` lists the options and the JSON fields); in a config entry, its `provider` is
`provider` and its `id` is `model`. It gets the models over pi's RPC
interface rather than from `pi --list-models`, so its list can include
models that `pi --list-models` doesn't (e.g. extra `github-copilot`
models), and those may not be usable on your account. It requires `pi` to be installed and can be run directly after
installing the gem; like agent-council, it needs WSL on Windows.

[pi-docs]: https://github.com/earendil-works/pi/tree/main/packages/coding-agent/docs
