# agent-council

Run one prompt through several AI coding agents at once, against your
own project, and get two things back: a **consolidated report** that is
better than any single agent's, and a **head-to-head comparison** of the
models and providers behind the agents, measured on speed, token usage,
cost, and quality.

agent-council runs the **same analytical prompt** through each agent,
under the coding-agent harness each one names: the
[Pi](https://github.com/earendil-works/pi) harness, for any provider's
models, or [Claude Code](https://code.claude.com/docs), for Anthropic's,
billed however your `claude` login is. The agents can use any mix of
harnesses, providers, and models, including the same model more than
once, or under each harness.

A **consolidator** agent then reads every agent's report, checks their
claims against the project where it can, and writes two reports:

- **The consolidated findings report**, better than any single agent's:
  - consensus findings;
  - unique findings;
  - contradictions.
- **A companion meta report**, on each agent:
  - its statistics: duration, token counts, and estimated cost;
  - how deeply it researched: did it read the code, run commands,
    verify its claims?
  - how much it added, as opposed to noise or errors.

Each agent's own report is saved too, and each run's measurements
(every agent's outcome, duration, token usage, and estimated cost)
go into a machine-readable `run.json`, so your runs build up into a
dataset for comparing models and providers on your own work.

**New to Ruby? [Install agent-council from scratch](INSTALL.md)**

## Why use it

### A council of second opinions

- **Catch what one model misses.** Different models notice different
  problems and weigh trade-offs differently; asking several surfaces
  blind spots that no single answer reveals.
- **Get one report to read, not five.** The optional consolidator reads
  every analyst report, checks their claims against your project where it
  can, and writes a synthesis, so you can see where the models agree and
  where they differ.

### A benchmark built from your own work

Public leaderboards tell you how models do on someone else's tasks.
agent-council tells you how they do on *yours*: your codebase, your
questions, your standards. Every run is a controlled experiment, with the
same prompt, the same repository, and, under each harness, the same tools,
at the same moment, so the differences you see are differences in the
models and in the providers serving them (and, in a run that mixes
harnesses, in the harnesses, whose tools and loaded context differ).

- **Speed.** Every agent's wall-clock duration, side by side. Find out
  which models answer in two minutes and which take twenty, and whether
  the wait buys anything.
- **Tokens and cost.** Input, cached input, and output tokens, and an
  estimated dollar cost where the harness can price the model, per agent
  and in total. See whether the model that costs ten times as much finds
  ten times as much. The cost is an estimate that can be far from what
  you pay, in either direction; see
  [How far to trust the cost](#how-far-to-trust-the-cost).
- **Quality.** The reports sit side by side, labeled by source. The
  consolidator shows which findings each model shared with the others,
  which only it found, and where models contradicted each other, and its
  *Agent performance* section assesses each agent's depth of research
  (did it read the code, run commands, verify its claims?) and how much it
  added, as opposed to noise or errors.
- **Providers, not just models.** Run the same model through different
  providers, such as its maker's API and an aggregator, and compare their
  latency, price, and reliability. Failures are recorded with their
  reasons, so an unreliable provider shows up in the record.
- **Evidence that accumulates.** Each run's measurements are saved in a
  machine-readable `run.json`. Over weeks of real work, those files
  become a dataset for choosing your default model, your ensemble, and
  your budget from your own results, not from marketing or hunches.

### Repeatable and cheap to set up

A prompt file and a short YAML config are all a run needs; every run's
reports, prompt, config, and measurements are saved together in a
timestamped directory, so a comparison can be rerun next month, against
next month's models.

Because the harness is chosen per agent, a comparison can also pit the
same model against itself under different harnesses. The project is at
an early stage; support for more harnesses, such as Codex, is among the
[planned features](DESIGN.md#18-status-and-future-work). See
[`DESIGN.md`](DESIGN.md) for the rationale.

## What makes a good fit

agent-council can help with any question about a set of readable files
(or about no files at all) that meets these conditions:

- **It can be asked in one prompt.** Agents run non-interactively, with
  no clarification or steering partway through.
- **It can be investigated by several agents at once without
  collisions.** Reading files and running read-only commands is fine.
  Agents run tests and builds only when the prompt permits them, and
  even then skip any that need shared services (databases, servers,
  fixed ports, Docker).
- **It has a text answer.** Only each agent's final message is saved as
  its report. Agents are told not to change the project and to keep
  temporary files in a scratch directory, which is deleted after the
  run. Actions such as posting or deploying would happen once per agent.
- **It gains from several independent answers and a synthesis of
  them.** Open-ended questions ("what's wrong with this?", "what should
  we do?") gain the most; one with an obvious answer gains nothing.

Weigh two costs as well: a council costs several times what one agent
costs and takes as long as its slowest agent plus the consolidation, and
whatever the agents read goes to their providers (see
[Safety and privacy](#safety-and-privacy)).

For a catalog of uses, from code review to choosing models, see
[`USE_CASES.md`](USE_CASES.md).

> **Between releases**, the documentation in the repository describes the
> next release, not the latest published one, so it may cover features
> (and a version) that are not yet in a released gem. The documentation
> installed with the gem matches the installed version.

## Quick start

A first run from scratch, using two models and a consolidator that
synthesizes their reports. The sections after this one cover each step
in detail.

1. **Install the prerequisites:** Ruby 3.3+ (or JRuby 10+) and the
   [`pi` CLI](https://github.com/earendil-works/pi) (`pi --version`). See
   [Prerequisites](#prerequisites), or [INSTALL.md](INSTALL.md) if you
   need to install Ruby too. These steps run every agent under pi; to
   run agents under Claude Code as well, or instead (then without pi),
   see [Choosing a harness](#choosing-a-harness).
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
     - harness: pi
       provider: <provider-1>
       model: <model-1>
     - harness: pi
       provider: <provider-2>
       model: <model-2>
   consolidator:
     harness: pi
     provider: <provider-1>
     model: <model-1>
   ```

6. **Write a prompt and run it** from that same directory (the prompt
   file can live anywhere):

   ```bash
   echo 'In one paragraph, what does this project do?' > what-is-this-prompt.md
   agent-council what-is-this-prompt.md
   ```

   This calls each configured model at your providers' usual rates. Any
   files an agent reads, and the output of any commands it runs, go to
   that agent's provider; see [Safety and privacy](#safety-and-privacy).

Each model's answer is saved as a Markdown file under
`agent-council-reports/<yyyy-mm-dd>/<hh-mm-ss>/reviews/`, and the
consolidated report is written to the run directory itself, split into a
`*_findings.md` file (findings, contradictions, and overall assessment, with
no front matter or orchestration tables, so it can be pasted into an AI chat as is) and a
`*_meta.md` file (front matter, tables, agents consulted, and agent
performance), or a single `_consolidated_...md` file if the model's report
couldn't be split; see
[What you get](#what-you-get). To add more models or change the
consolidator, see
[Discovering and configuring models](#discovering-and-configuring-models).

## Prerequisites

- Ruby 3.3 or later, or JRuby 10 or later (standard library only for the
  tool itself; CI tests 3.3, 3.4, 4.0, JRuby 10.0 and the latest
  JRuby)
- The harness CLIs your config uses (each run checks for them first):
  - for pi: the
    [`pi` CLI](https://github.com/earendil-works/pi)
    (`pi --version`), 1.0.4 or later, for `--no-mcp` (tested with pi
    1.3.0, 1.4.0, and 1.5.2), with credentials for at least one provider
    (several give more diverse viewpoints), configured through pi itself
    (see [pi's documentation][pi-docs]);
  - for Claude Code: the [`claude` CLI](https://code.claude.com/docs)
    (`claude --version`; tested with 2.1.325 and 2.1.327, and earlier versions may
    lack flags agent-council passes),
    logged in or set up with an API key.

  agent-council runs the `pi` and `claude` executables found on its
  `PATH`, not your shell's aliases or functions of those names. If yours
  add something, such as an environment variable or a directory on
  `PATH`, set it in the environment you run agent-council from (for
  one case, see
  [Claude Code's sandbox](#claude-codes-sandbox)).
- On Windows, WSL (e.g. Ubuntu): native Windows is not supported. Install
  and run Ruby, the harness CLIs your config uses, and agent-council
  inside WSL, from a WSL shell
  ([INSTALL.md](INSTALL.md) has the steps). Windows drives are reachable
  at `/mnt/c/...`, but file access there is much slower than in the Linux
  filesystem (e.g. `~/projects`). Set up pi's provider credentials (and
  log in to Claude Code) inside WSL too; WSL doesn't share them with
  Windows.

## Installation

With [the prerequisites](#prerequisites) in place (or following
[INSTALL.md](INSTALL.md) from scratch), install the gem to make the
`agent-council` command available on your RubyGems executable path:

```bash
gem install agent-council
agent-council -h
```

The gem creates no config for you; it ships samples in `examples/configs/`. See
[Discovering and configuring models](#discovering-and-configuring-models)
to write one. To work on agent-council itself, see
[Development](#development).

### Finding the installed documentation and examples

The installed gem contains this README, [`INSTALL.md`](INSTALL.md),
[`USE_CASES.md`](USE_CASES.md), [`DESIGN.md`](DESIGN.md),
`RELEASE_NOTES.md`, and the sample prompts and configs under
`examples/`, all matching the installed version. The help
output shows where they are for the copy of `agent-council` you are
actually running:

```bash
agent-council -h   # see "Documentation (Local)" and "Examples (Local)"
```

To get that copy's directory in a shell variable, used by the examples
below:

```bash
AC_HOME=$(agent-council --gem-dir)
```

## Discovering and configuring models

```bash
pi --list-models                 # models of the providers you have credentials for
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
run of the harness it names (see
[Choosing a harness](#choosing-a-harness)) with that
model and provider (see
[How it works](#how-it-works-and-what-the-agents-are-told) for the full commands), so no Ruby changes
are needed to add, remove, or swap models. A small config (replace the
providers and models with ones you have credentials for):

```yaml
# agent-council.yml
agents:
  - harness: pi
    provider: opencode-go
    model: kimi-k2.7-code
  - harness: pi
    provider: openai
    model: gpt-6.1-sol
consolidator:            # optional; omit to skip consolidation
  harness: pi
  provider: opencode-go
  model: kimi-k2.7-code
```

Use at least two agents: a council of one gives a single viewpoint, and
consolidating a single report adds cost without adding anything.

The config must be a YAML mapping with a non-empty `agents` list. Each
agent, and the consolidator, needs nonblank string `harness`,
`provider`, and `model` values (quote any value YAML would read as
something else, such as a number, a date, or `yes`). None has a default;
a 0.1.0 config needs `harness: pi` added to each entry. `harness` names
the harness the entry runs under, `pi` or `claude`; an unknown name is
rejected at startup (with `--consolidate`, only the consolidator's,
since no analysts run). Other keys are ignored. A config error lists
every bad entry, named as in `'agents' entry #2` or `'consolidator'`,
with every problem it has.

More samples are in [`examples/configs/`](examples/configs/), which is
included in the installed gem; `mixed-harness.yml` mixes pi and Claude
Code agents. For scripts and agents,
[`pi-models`](#occasional-utility-pi-models) lists the models in
machine-readable forms.

An optional top-level `consolidator:` entry (the same shape as an
agent's: a harness, a provider, and a model) runs after all agents
finish. That model receives:

- the original prompt;
- the analyst reports in `reviews/`, each labeled with its source model;
- a list of the agents without a report, each with its harness and its
  failure reason, followed by any warnings about its run;
- the instructions in `lib/agent_council/templates/consolidate_prompt.md`
  in the gem's directory (`$AC_HOME`; see
  [Finding the installed documentation and examples](#finding-the-installed-documentation-and-examples))
  or a source checkout, where you can edit it to tune the consolidation.

agent-council saves its response as a report in the run dir itself (see
[What you get](#what-you-get) for its name). Remove the key to skip consolidation. To
consolidate a run that has already finished, see
[Consolidating a finished run](#consolidating-a-finished-run).

### Choosing a harness

An entry with `harness: claude` runs under
[Claude Code](https://code.claude.com/docs) instead of pi, so one config
can mix the two, and can compare a model under each:

```yaml
agents:
  - harness: pi
    provider: openai
    model: gpt-6.1-sol
  - harness: claude
    provider: anthropic
    model: claude-opus-5-5
consolidator:
  harness: claude
  provider: anthropic
  model: claude-sonnet-5-5
```

- **Models.** `model` is any model name or alias `claude --model`
  accepts. Claude Code takes no provider, so `provider` only labels the
  run: `anthropic`, or e.g. `bedrock` if your `claude` is set up to use
  it.
- **Billing.** agent-council leaves authentication and billing to Claude
  Code: an agent bills however `claude` would at your terminal, to your
  subscription if you are logged in with one, or to an API key if one is
  configured. Unlike an interactive session, `claude -p` doesn't ask
  before using an `ANTHROPIC_API_KEY` in your environment, so a key
  exported for another tool bills council runs to the API. On a
  subscription, agents share your plan's usage limits with your
  interactive work (several agents at once use them up faster), and the
  reported cost is Claude Code's estimate at API prices, not a charge
  (see [How far to trust the cost](#how-far-to-trust-the-cost)).
- **Context.** Each agent runs as an interactive session started in your
  project would, so your `CLAUDE.md` files, settings, hooks, and plugins
  apply, and so does Claude Code's auto memory: agents see the memory
  notes Claude Code has kept for the project, and are told, as an
  interactive session is, that they may add to them. See
  [Safety and privacy](#safety-and-privacy).
- **Refused tool calls.** Claude Code can still refuse a tool call, for
  example one that a `permissions.deny` rule in your settings or the
  project's forbids. The agent then carries on without it; its report is
  kept, and a warning naming the call (up to five distinct calls, with a
  count of the rest) is printed under its progress line (the
  consolidator's, under its result table), shown in the report's
  metadata table (so the consolidator sees an analyst's too), and
  recorded in `run.json`, since the report may lack what the call would
  have found. If the run fails anyway (say, it runs out of turns after
  repeated refusals), the warning still follows its failure reason, on
  the console, in `run.json`, and in what the consolidator is told about
  it, since the refusals may be why it failed.

## Running

```bash
cd /path/to/the/repo/you/want/analyzed
agent-council /path/to/prompt.md
```

There is no option to choose the directory analyzed: each agent analyzes its
**own working directory**, which is the directory you run `agent-council` from. Run it from
the project you want analyzed; the prompt file can live anywhere, as can a
config given as an argument.
Reports land in `./agent-council-reports` under that working directory,
so each analyzed project gets its own reports tree. To put them
elsewhere, pass `-o DIR` / `--output-dir DIR`; a relative `DIR` is
resolved against the working directory. (An explicit `--output-dir` can't be
combined with `--consolidate`, which works on the reports of an existing
run and writes its consolidated report into that run's directory.)

```bash
# Uses ./agent-council.yml, else ~/.agent-council.yml
agent-council my-analysis-prompt.md
# Uses another config
agent-council my-analysis-prompt.md other-config.yml
# Writes reports under ./tmp/council
agent-council -o tmp/council my-analysis-prompt.md
# Usage, options, and any AGENT_COUNCIL_OPTS value
agent-council -h
# Version
agent-council -v
# Root directory of agent-council, holding its docs and examples
agent-council --gem-dir
# The project's GitHub URL
agent-council --project-url
# See Consolidating a finished run
agent-council --consolidate agent-council-reports/2026-09-03/09-14-02
```

Relative paths are resolved from the working directory. agent-council
expands `~` itself only in `--output-dir`; in other paths, the shell
must expand it.

[`examples/`](examples/) holds sample prompts and configs — pure samples, not
used at runtime. `examples/prompts/` and `examples/configs/` are included in
the installed gem. The commands below use `$AC_HOME`, agent-council's
root directory (see [Finding the installed documentation and
examples](#finding-the-installed-documentation-and-examples)). To use a
source checkout instead, use its `exe/agent-council` wherever
`agent-council` appears, including when setting `AC_HOME`: run it by its
full path, or put its `exe/` on your `PATH` (see
[Development](#development)). They still analyze your
current directory, and the sample configs name specific providers and
models — copy and edit one if yours differ.

- `examples/prompts/state-of-the-code-base-prompt.md` — a real codebase-analysis
  prompt; with `examples/configs/consolidated.yml` this is the full
  ensemble:

```bash
agent-council \
  "$AC_HOME/examples/prompts/state-of-the-code-base-prompt.md" \
  "$AC_HOME/examples/configs/consolidated.yml"
```

- `examples/prompts/smoke-test-prompt.md` +
  `examples/configs/single.yml` — a tiny, cheap prompt (one multiplication
  question — enough to prove a real answer came back) and a one-model
  config, for verifying your setup in seconds (the
  [report-format addendum](#how-it-works-and-what-the-agents-are-told) may wrap
  the number in a short report):

```bash
agent-council \
  "$AC_HOME/examples/prompts/smoke-test-prompt.md" \
  "$AC_HOME/examples/configs/single.yml"
```

- `examples/prompts/project-name-prompt.md` + `examples/configs/consolidated.yml` —
  a small creative-writing prompt useful for spotting prompt-sensitivity
  differences across models:

```bash
agent-council \
  "$AC_HOME/examples/prompts/project-name-prompt.md" \
  "$AC_HOME/examples/configs/consolidated.yml"
```

- `examples/prompts/recommend-model-ensemble-prompt.md` — a reusable prompt
  for recommending a provider-diverse model ensemble for a task (agents
  run [`pi-models`](#occasional-utility-pi-models), which is on your
  `PATH` once the gem is installed, and otherwise say they need a model
  list); its sample
  code-review recommendation is in
  [`examples/results/recommend-model-ensemble-code-review.md`](https://github.com/keithrbennett/agent-council/blob/main/examples/results/recommend-model-ensemble-code-review.md)
  (generated output, in the source repository only — not in the gem).
- `examples/prompts/review-latest-commit-prompt.md` — a code-review prompt
  for the latest commit (plus any uncommitted changes); run it from the
  repository under review with a multi-model config.
- `examples/prompts/review-pull-request-prompt.md` — the same review for a
  GitHub pull request, plus its unaddressed review comments and failing
  checks. Check out the PR first (`gh pr checkout <number>`) and run from
  that checkout; agents need an authenticated
  [`gh`](https://cli.github.com/) and read the PR through it.
- `examples/prompts/review-docs-prompt.md` — a documentation review: checks
  the README, other Markdown files, help output, code comments, and samples
  against the code for accuracy, completeness, consistency, first-run
  usability, and clarity (including duplication);
  run it from the repository whose docs you want reviewed.
- `examples/prompts/test-coverage-analysis-prompt.md` — a line-coverage
  analysis organized by the logical parts of the system, with gaps ranked by
  risk and a ready-to-use prompt for each recommended fix. It reads
  SimpleCov's `coverage/coverage.json` through
  [cov-loupe](https://github.com/keithrbennett/cov-loupe) and runs no tests,
  so run your full test suite first; it stops with an error if the coverage
  data looks out of date.

### Setting your own defaults with `AGENT_COUNCIL_OPTS`

To use the same options on every run, put them in the
`AGENT_COUNCIL_OPTS` environment variable. agent-council inserts its
arguments before the command-line ones, so an option given on the command
line overrides the same option there:

```bash
export AGENT_COUNCIL_OPTS="--output-dir tmp/council"
agent-council my-analysis-prompt.md
# Overrides AGENT_COUNCIL_OPTS
agent-council --output-dir other-reports my-analysis-prompt.md
```

Its arguments are treated exactly as if typed first on the command line,
so set it with care: for example, an `--output-dir` there makes
`--consolidate` fail, as if both were typed on the command line. The value is split into
words like a shell would, but agent-council doesn't expand variables in
it: `~` works, but a literal `$HOME` stays literal. (In a double-quoted
`export`, your shell has already expanded it.) A malformed value, such as
one with an unclosed quote, makes every command fail, `-h`, `-v`,
`--gem-dir`, and `--project-url` included, with a message naming
`AGENT_COUNCIL_OPTS`.

### Stopping a run

Ctrl-C (or SIGTERM, SIGHUP, or SIGQUIT) stops the run, keeping reports
already written:

- Running agents, the consolidator included, get SIGTERM (pi and Claude
  Code then also stop the commands they started) and a shared 5 seconds to exit before
  they are killed. A killed agent can't stop the commands it started, so
  those may keep running.
- A second SIGINT, SIGTERM, or SIGQUIT kills them at once; further SIGHUPs
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
`reviews/`, and writes its report (split into findings and meta files,
as in a normal run) into the same run dir, named as in a normal run, with the run's original `run_stamp` (its date and time, plus
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
  - A run made by agent-council 0.1.0, before entries named their
    harness, has a consolidator with no `harness`; it ran under pi, so
    add `harness: pi` to it (the error message says so).
  - Leave the copy's `agents:` exactly as they were (same order,
    harnesses, providers, and models): an agent counts as having no
    report when no report carries its number, provider, and model.
- **The consolidation instructions are the current template's** (the
  installed gem's, or a checkout's own), which may have changed since
  the run.
- **Existing reports are kept.** If a file with the name the new
  report would get, or the name of its `_findings` or `_meta` file, already
  exists (as it does when the same model configuration, meaning harness,
  provider, and model, consolidated the run before), nothing runs; rename
  or delete the file or files the message lists to redo it. Reports
  from different model configurations have different names and sit side
  by side, so you can compare their syntheses.
- **The run needs at least one analyst report written by
  agent-council**: the prompt and config copies are found through the
  reports' front matter (`prompt_file` and `config_file`, with
  `run_stamp` and `query` naming the consolidated report). A run where
  every analyst failed, or that was interrupted before any report was
  written, can't be consolidated.
- **Failure reasons come from `run.json`.** The consolidator is told
  each configured agent without a report, with the error and warnings
  `run.json` records for its failed run; for an agent with no such
  entry (an interrupted run, a removed report, or no readable
  `run.json`), with a note that the reason wasn't recorded.

### Time zone

Run dir names, report filenames, and the front matter's `timestamp` and
`consolidated_at` all use the **local time zone**. There is no
agent-council option to change it; instead, set the standard `TZ`
environment variable, which Ruby (like most programs) honors. Timestamps
always carry their UTC offset (`2026-09-02T16:21:43+00:00` in UTC), so
they stay unambiguous whatever the zone.

| Platform | One run in UTC | Value format |
|---|---|---|
| Linux, macOS, WSL (bash, zsh, fish) | `TZ=UTC agent-council prompt.md` | IANA name [[1]][tz-iana] |
| Windows PowerShell | `$env:TZ = 'UTC0'; agent-council prompt.md` | POSIX-style [[2]][tz-gnu] [[3]][tz-posix-db] [[4]][tz-ms] |
| Windows cmd | `set "TZ=UTC0" && agent-council prompt.md` | POSIX-style [[2]][tz-gnu] [[3]][tz-posix-db] [[4]][tz-ms] |

On Windows, `TZ` set this way lasts for the rest of the shell session.
Git Bash on Windows accepts the Linux syntax but runs Windows Ruby, so it
takes POSIX-style values.

**Finding the value to use:**

- **IANA names** (Linux, macOS, WSL): `Area/City`, such as
  `America/Chicago` or `Europe/Berlin`, plus `UTC`. List them with
  `ls /usr/share/zoneinfo`, or see the list on Wikipedia [[1]][tz-iana].
  A misspelled name isn't reported: it silently falls back to UTC, so
  check the timestamp in a report's front matter.
- **POSIX-style values** (native Windows): a zone abbreviation, its
  hours **west** of UTC (so the sign is the reverse of the usual
  offset), and an optional daylight saving abbreviation: `UTC0`,
  `EST5EDT` (US Eastern), `PST8PDT` (US Pacific), `CET-1CEST`
  (Central Europe). The GNU C Library manual explains the format with
  examples [[2]][tz-gnu]; to find your zone's value, look up its IANA
  name in the `posix_tz_db` table [[3]][tz-posix-db] and use the part
  before the first comma (`America/Chicago` gives
  `CST6CDT,M3.2.0,M11.1.0`, so use `CST6CDT`), since Windows doesn't
  support the daylight saving rules after it and always follows US
  rules instead [[4]][tz-ms]. These values also work on Linux and
  macOS.

References:

1. [List of tz database time zones](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) (Wikipedia)
2. [The TZ Variable](https://www.gnu.org/software/libc/manual/html_node/TZ-Variable.html) (GNU C Library manual)
3. `posix_tz_db`: [IANA names mapped to POSIX TZ strings](https://github.com/nayarsystems/posix_tz_db/blob/master/zones.csv)
4. `_tzset`: [Microsoft C runtime documentation](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/tzset)

[tz-iana]: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
[tz-gnu]: https://www.gnu.org/software/libc/manual/html_node/TZ-Variable.html
[tz-posix-db]: https://github.com/nayarsystems/posix_tz_db/blob/master/zones.csv
[tz-ms]: https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/tzset

To always use a zone, set `TZ` in your shell profile (e.g.
`export TZ=UTC`), keeping in mind that this affects every program
started from that shell. The agents inherit `TZ` either way, so it also
changes the time they see.

## What you get

Each run creates one run directory, holding its inputs and reports,
day-bucketed
(`--consolidate` instead writes into the existing run directory it is
given):

```text
agent-council-reports/
  2026-09-02/
    16-21-43/
      codebase-review.md   # prompt copy
      analyst_format.md    # report-format addendum copy
      consolidated.yml     # config copy
      run.json             # every agent run's outcome, duration, and token usage
      reviews/             # analyst reports
        2026-09-02-16-21-43_codebase-review_01_pi_opencode-go_glm-5.3.md
        2026-09-02-16-21-43_codebase-review_02_pi_opencode-go_kimi-k3.md
        2026-09-02-16-21-43_codebase-review_03_pi_openai_gpt-6.1-sol.md
        2026-09-02-16-21-43_codebase-review_04_pi_cursor_claude-sonnet-5-5-high.md
      # consolidated report, if a consolidator is configured, normally in two
      # files: the findings, ready to paste into a chat, and the run's
      # metadata (a report that can't be split is one file, without the
      # _findings or _meta suffix)
      2026-09-02-16-21-43_codebase-review_consolidated_pi_opencode-go_glm-5.3_findings.md
      2026-09-02-16-21-43_codebase-review_consolidated_pi_opencode-go_glm-5.3_meta.md
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
- **Time zone**: local by default; see [Time zone](#time-zone) to use
  UTC or another zone.
- **Report filenames** carry everything else:
  `<yyyy-mm-dd>-<hh-mm-ss>_<query-slug>_<agent-number>_<harness>_<provider>_<model>.md`,
  so a report stays self-describing when you copy or attach it outside the
  tree (a consolidated report has `consolidated` in place of
  `<agent-number>`, and, if the report was split, ends in `_findings` or `_meta` before `.md`); `<hh-mm-ss>` includes the run dir's suffix, if any,
  and `<provider>` and `<model>` are sanitized like the query slug below,
  but keep their case. `<harness>` is the agent's (or consolidator's)
  `harness` config value, `pi` or `claude` (see
  [Choosing a harness](#choosing-a-harness)).
  `<agent-number>` is the agent's 1-based position in the config's
  `agents` list (`01`, `02`, ...), so every report has a unique name even
  if the same provider/model is configured more than once. The query slug
  is the prompt file name without its extension, minus any trailing
  `-prompt` or `_prompt` in any case (`codebase-review-prompt.md` and
  `codebase-review_prompt.md` both become `codebase-review`), lowercased, with each run of characters
  other than ASCII letters, digits, `.`, `_`, and `-` replaced by `-` and
  leading or trailing `-` and `.` dropped (`My Prompt (draft).md` becomes
  `my-prompt-draft`); a name left empty becomes `prompt`.
- **Day buckets** keep the reports directory itself navigable when you have hundreds
  of runs.
- Each report file, except a consolidated report's `*_findings.md`, begins with a small **YAML front matter** block,
  written by the orchestrator (never by the model), identifying the
  report (what was measured about its run is in `run.json`, below):
  - in every report: `role` (`analyst` or `consolidator`), `timestamp`
    (unquoted ISO 8601), `query` (the query slug), `harness`, `provider`, `model`,
    `prompt_file` and `config_file` (the names of
    the run dir's input copies), `config_source` (where the config was
    found, with `~` for the home directory; informational only) and
    `run_stamp` (the report filenames' date-time prefix, with the run
    dir's suffix, if any);
  - in analyst reports: `agent_index` (the agent number, as an integer);
  - in consolidated reports: `sources` (the analyst labels that were
    synthesized) and `consolidated_at` (when the
    consolidation ran; with `--consolidate`, possibly long after
    `timestamp`, the run's start).

- The run dir's **`run.json`** records every agent run, for tools and
  for analysis across many runs: `analysts` and `consolidations`, one
  entry per run with its `agent_index` (analysts only), `harness`,
  `provider`, `model`, `ok`, `duration_seconds`, `usage`, and `report` (its
  path in the run dir; for a split consolidation, the `*_findings.md` file)
  or `error`. A split consolidation also has `meta_report`, the `*_meta.md`
  file, which has the front matter. Any entry the harness warned about
  (such as a Claude Code run with refused tool calls) also has
  `warnings`, a list of messages. The file also has `total_usage`, the
  entries' summed usage, whose `cost` is included only if every summed
  entry's cost is known; and `total_usage_runs`, how many entries reported
  usage (and so are in the total). Failed runs are included, since their
  tokens were spent, but a Claude Code run that ends without its final
  `result` event (e.g. because its `claude` was killed) reports no usage,
  since only that event gives the run's totals.
  It is written once the reviews finish and updated after each
  consolidation, including each `--consolidate`; a `--consolidate` of a
  run dir without a readable `run.json` warns and writes none.

  `usage` is the model's token usage, summed over every request of the
  run, as reported by the harness: `input` (excluding cached input),
  `cache_read`, `cache_write`, and `output` token counts, plus `cost` in
  US dollars when the harness could price the run (pi uses its own price
  table, so models missing from it have no cost; Claude Code prices runs
  at Anthropic's API list prices), recorded as the harness reports it,
  only rounded to six decimal places. It is an estimate, not what you're
  billed; see [How far to trust the cost](#how-far-to-trust-the-cost).
  `usage` is `null` when the provider reports no usage.

  `--consolidate` relies on the analysts' `prompt_file`, `config_file`,
  `run_stamp`, and `query`, and on `agent_index` to tell which configured
  agents have no report. Reports are identified by their front matter,
  not by filename parsing, so `.md` files in `reviews/` without
  `provider` and `model` front matter are ignored.
- Below the front matter, the orchestrator adds a metadata table
  summarizing its main fields, its run's duration and token usage, and
  any warnings about the run, such as tool calls Claude Code refused
  (for consolidated reports, under a `# Consolidated Report` title and a
  `### Prompt:` line, and followed by a `### Sources` table giving each
  source's duration, input (cached included), cached input, output, and
  cost, from `run.json`), followed by the
  model's final message, minus any top-level `#` heading the message
  starts with. The consolidator is asked to put a line containing only `=== META ===`
  between its findings and its `Agent Consultants` and `Agent performance`
  sections, and the report is split there: the text after the marker stays
  with this header and front matter in the `*_meta.md` file, and the text
  before it goes to the `*_findings.md` file under a `# Consolidated Findings`
  title, a few lines identifying the run (its stamp and query, the prompt
  file, the consolidator and time, and any warnings about the
  consolidator's run), and a legend of the agents (number,
  harness, provider, model). If
  the marker is missing, repeated, inside a code fence, or not followed by
  the `Agent Consultants` heading, or the report no longer starts with the
  header written to it, the report is left unsplit, under the unsuffixed
  name, and a warning says why.
- The copied prompt, config, and report-format addendum keep an analyst
  run's inputs recoverable after the fact. The harness and
  agent-council versions, the scaffolding text appended to the harness's
  system prompt, and the
  consolidation template are not recorded.
- The prompt and config copies keep their own file names (e.g.
  `single.yml`), so the prompt, the config, and `analyst_format.md` must
  have different file names, and none can be named `reviews`; a run that
  would break either rule stops before starting.

Each run starts by printing its config, prompt, and run directory
(`Run Dir: agent-council-reports/2026-09-03/09-14-02`), then its agents
under `Review Agents (N):` and, if configured, `Consolidator Agent:`;
these labels also name the harness (e.g. `#2 pi / openai / gpt-6.1-sol`).
You can open the run dir while agents are still working, or after a
Ctrl-C (see [Stopping a run](#stopping-a-run)). Other access patterns:

```bash
# Last run by name: usually the newest
ls -d agent-council-reports/*/* | tail -1
# Today's runs
ls agent-council-reports/$(date +%F)/
# Every analyst report for one question, all runs
ls agent-council-reports/*/*/reviews/*codebase-review*
```

While the agents run, a `Review Progress:` section prints one line per
agent as it finishes: `✓` or `✗`, its duration, its label (e.g.
`#2 openai / gpt-6.1-sol`) and, for a failure, the reason on the line
below; any warnings about a run (such as tool calls Claude Code
refused) follow as indented `Warning:` lines, under its progress line or,
for the consolidator, under its result row. When all reviews finish, a `Reviews` table shows which models
succeeded, how long each took (`HH:MM:SS`) and their token usage in
`In`, `Cached`, `Out`, and `Cost` columns (`In` counts cached input too;
`-` when unknown; failed runs show what they used; `Cost` is an estimate,
see [How far to trust the cost](#how-far-to-trust-the-cost)), with the failures'
reasons listed below it under `Errors:`. A
`--- Reviews complete (N/M succeeded; <total usage>) ---` line follows,
e.g. `2.1M in (2.0M cached) / 32.7k out, $0.18`. The total's cost is
shown only when every counted analyst's cost is known, and the total
notes `(from K of M agents)` when some reported no usage (as some
providers don't). With a consolidator,
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

### How far to trust the cost

Every cost agent-council shows or records is the harness's estimate
from per-token prices, not a bill, and it can be far off in either
direction:

- **Subscriptions.** On a subscription or plan (a Claude Code login, or
  a plan-based pi provider), the estimate is what the usage would cost
  at pay-per-token prices. What you actually pay for a run may be
  nothing extra, while the run uses up your plan's limits.
- **Price tables.** pi prices runs from its own price table, which may
  not match what your provider charges (discounts, price changes, or
  routing to a differently priced upstream), and a model missing from
  it gets no cost at all. Claude Code prices runs at Anthropic's API
  list prices.
- **Stopped runs.** An agent stopped by Ctrl-C (or another signal)
  records no usage, though its provider still bills for what it used,
  and a run stopped before every analyst finished writes no `run.json`
  at all. A runaway agent stopped by hand, the most expensive kind of
  run, is therefore missing from the totals entirely.
- **Token counts.** Providers count tokens somewhat differently
  (reasoning tokens, for example), so compare counts, and the costs
  built on them, across providers only roughly.

For what you were actually charged, check your provider's billing or
usage page.

## How it works (and what the agents are told)

- Every analyst agent receives the **same bytes**: the prompt file's
  contents (with one trailing newline removed), a blank line, and the
  report-format addendum
  (`lib/agent_council/templates/analyst_format.md`, copied into each run
  dir), piped to the agent's harness on stdin as the prompt. No roles, no per-model customization. The addendum asks for a
  Markdown report with `##` section headings, which can conflict with a
  prompt that asks for some other output form (the smoke-test prompt's
  "Reply with just the number, then one sentence explaining how you got
  it.", for example); models usually reconcile the two. (The
  consolidator gets its own prompt; see
  [Discovering and configuring models](#discovering-and-configuring-models).)
- Under pi, each agent runs as
  `pi -p --mode json --no-session --no-mcp --tools read,grep,find,ls,bash
   --provider P --model M --append-system-prompt <scaffolding>`.
  - `--no-session` keeps runs independent: no conversation state leaks
    between ensemble members.
  - `--no-mcp` turns off pi's built-in MCP support, so the MCP servers
    configured for pi don't start and agents have no MCP tools. (An
    extension that provides its own MCP support isn't affected.)
  - `--tools` is an allowlist for pi's built-in, extension, and custom
    tools: `bash` remains for investigation (`git log`, dependency
    inspection, ...), while file-editing tools and unlisted extension and
    custom tools are unavailable.
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
- Under Claude Code, each agent runs as
  `claude -p --output-format stream-json --verbose --no-session-persistence
   --tools Read,Grep,Glob,Bash --allowedTools Read,Grep,Glob,Bash
   --permission-mode manual --strict-mcp-config --model M
   --append-system-prompt <scaffolding>`.
  - `--no-session-persistence` keeps runs independent: no session is
    saved, to be resumed or to show up in your session list.
  - `--tools` limits the built-in tools to these four: `Bash` remains for
    investigation, while `Edit`, `Write`, and the rest are unavailable.
    `--allowedTools` pre-approves the four, since `-p` mode can't ask
    (a call that needs approval is refused), and `--permission-mode
    manual` keeps your own default mode (such as `plan`) from applying.
  - `--strict-mcp-config`, with no `--mcp-config`, loads no MCP servers,
    neither yours nor a plugin's, so agents have no MCP tools. (Where an organization manages Claude
    Code's MCP servers with a `managed-mcp.json`, Claude Code's own
    message says it refuses this flag, which would fail every Claude Code
    agent; that case is untested.)
  - Otherwise Claude Code behaves as an interactive session started in
    the analyzed repo would: it loads `CLAUDE.md` files (and what they
    import, such as `@AGENTS.md`), your user and the project's settings,
    hooks, and plugins, and its auto memory for the project (the
    `MEMORY.md` index, with the instruction to keep it up to date).
    (`--bare`, which would skip them, also permits only API-key
    authentication, so it isn't used.)
  - The final response is the stream's `result` event; a run that fails
    (not logged in, an unknown model, the output cut off) is reported
    with the reason Claude Code gives. [`DESIGN.md`](DESIGN.md) §13 has
    the details.
- The tool limits and the MCP settings above are the only restrictions
  agent-council enforces (see [Safety and
  privacy](#safety-and-privacy)). A fixed scaffolding text appended to
  the system prompt (identical for all agents, the consolidator
  included) tells agents not to modify project files, git state,
  software, or configuration, or start persistent services (they get a
  scratch directory for temporary files), and not to run tests, builds,
  or similar commands, which can collide between concurrent analysts,
  unless the prompt permits them (as
  `examples/prompts/review-latest-commit-prompt.md` does for tests and
  linters); where such a command isn't permitted but would help, the
  agent describes what it would run instead. The full text is
  `scaffold_text` in `lib/agent_council/harnesses/scaffold.rb`;
  [`DESIGN.md`](DESIGN.md) §10 explains the rules.
- Each agent gets its own disposable temp directory, as its `TMPDIR`,
  which the scaffolding tells it to use for scratch space, deleted after
  the run (under Claude Code's sandbox, `TMPDIR` is a directory Claude
  Code makes inside it; see [Claude Code's
  sandbox](#claude-codes-sandbox)). After Ctrl-C, a directory can be
  left behind if a second signal stops agent-council at once, or if
  cleanup after a killed agent doesn't finish in time.

## Safety and privacy

agent-council does not sandbox the agents (Claude Code's own sandbox,
off by default, restricts Claude Code agents' commands if Claude
Code's settings enable it, and the analyzed repository's settings can
enable or disable it; see
[Claude Code's sandbox](#claude-codes-sandbox)).
Before running it, know that:

- **Agents have a shell.** Each agent, the consolidator included, gets a
  shell tool (pi's `bash`, or Claude Code's `Bash`), running as you, in
  the directory you run from, with your environment (including any API
  keys in it; agent-council only sets `TMPDIR` and `CLAUDE_CODE_TMPDIR`,
  both to the agent's scratch directory), your file permissions, and
  your network access (for Claude Code agents, unless its sandbox
  restricts writes and network access). Of pi's built-in tools, only
  `edit` and `write` (and the Windows-only `powershell`) are withheld;
  of Claude Code's, all but `Read`, `Grep`, `Glob`, and `Bash`. The
  read-only rules described above are instructions in the system prompt,
  which a model can ignore or misapply.
- **Your pi extensions, and your Claude Code hooks and plugins, load.**
  `--no-mcp` turns off only pi's built-in
  MCP support. Extensions you've installed load for every pi agent, as
  you, and one that provides its own MCP support can still start servers.
  Your Claude Code hooks and plugins run for every Claude Code agent, as
  you, and so do hooks the analyzed repository's `.claude` settings
  define (see the next item). Agents also get Claude Code's auto memory
  for the project, so your memory notes go to their provider, and an
  agent may add or change a memory file (with `Bash`), as an
  interactive session may. `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` in the
  environment you run agent-council from turns auto memory off.
- **The analyzed repository can steer the agents.** Agents read the
  repository's files, and the harness loads the repository's context
  files and settings: pi its context files (such as `AGENTS.md`) and, if
  the project is trusted, its `.pi` resources; Claude Code its
  `CLAUDE.md` files and `.claude` settings, which apply without the
  trust prompt an interactive session would show first (their hooks,
  for one, run commands; checked). So the repository can direct what
  runs: its text by prompt injection, and its hooks by running commands
  of their own, whatever the agent does. To run Claude Code agents
  without customizations, whether the repository's or yours (hooks,
  plugins, skills, and the like), set `CLAUDE_CODE_SAFE_MODE=1` in the
  environment you run agent-council from. Permission rules and admin-managed settings still apply. It also
  skips `CLAUDE.md` files, so agents no longer see the project's own
  instructions. Prompts that permit tests, such as
  `examples/prompts/review-latest-commit-prompt.md`, run the project's
  own code.
- **Your code goes to every configured provider.** Whatever an agent reads,
  and the output of whatever it runs, is sent to that agent's provider
  (for a Claude Code agent, wherever your `claude` sends it: Anthropic,
  unless it is set up for another). The
  consolidator's provider receives the prompt and all reports, plus
  anything the consolidator itself reads or runs. Check those providers'
  data policies before analyzing private code.
- **Reports stay in the analyzed project by default.** They are written
  under `agent-council-reports/` in the working directory, unless you give
  an `--output-dir`; add that directory to the project's `.gitignore` if
  you don't want them committed.

Run agent-council only on repositories you trust, or inside a container, VM,
or disposable checkout that holds no credentials you aren't willing to
expose.

### Claude Code's sandbox

agent-council doesn't turn Claude Code's sandbox on or off: Claude
Code's settings decide (`sandbox.enabled`, off by default), as in an
interactive session, including settings committed to the analyzed
repository, which can enable it or disable one you enabled (only
`--settings` or managed settings take precedence over them). When it's
enabled, Claude Code agents' `Bash` commands run in it, except those
matching `sandbox.excludedCommands`, which run outside it, and to which
the analyzed repository's settings can add (not checked). The points
below are from Claude Code's [sandboxing
docs](https://code.claude.com/docs/en/sandboxing) unless marked as
checked; most apply on any platform, the last two were checked on Linux.

- **It doesn't protect the repository.** The working directory, which is
  the analyzed repository, stays writable, apart from protected files
  such as the `.claude` settings files and `.git/hooks`. In a check
  (Claude Code 2.1.325, with the sandbox's other settings at their
  defaults), it blocked network access and writes to the home directory
  outside the working directory; reads weren't checked.
- **An agent's request to run a command outside it was refused.** Claude
  Code's docs say an allow rule matching a command also approves an
  unsandboxed retry without a prompt, but in a check (Claude Code
  2.1.327) with agent-council's options, the retry was refused, and
  Claude Code reported the refusal, which agent-council shows as a
  warning. To disable such retries altogether, set
  `sandbox.allowUnsandboxedCommands` to `false` in your user settings
  (the analyzed repository's settings could otherwise override it). This
  doesn't affect `sandbox.excludedCommands`.
- **The scratch directory itself isn't writable.** Inside the sandbox,
  Claude Code points `TMPDIR` at a directory of its own inside
  agent-council's scratch directory (agent-council sets
  `CLAUDE_CODE_TMPDIR` so that it is). In a check (2.1.327), writes under
  `$TMPDIR` worked, but writes to the scratch directory's own path
  failed ("read-only file system"). The scaffolding sends agents to
  `$TMPDIR`, not to that path, so this only matters to an agent that
  finds the path some other way.
- **agent-council doesn't notice other sandbox trouble.** When the
  sandbox can't start, commands run unsandboxed unless
  `sandbox.failIfUnavailable` is `true`; an agent whose commands fail or
  run unsandboxed is still reported like any other.
- **Every `Bash` call failed** in a check on Ubuntu, whose AppArmor
  restricts unprivileged user namespaces, with a `setgroups` error from
  the distribution's `/usr/bin/bwrap` (bubblewrap, which runs the
  sandbox on Linux, alongside `socat`). The docs' fixes are an AppArmor
  profile for `/usr/bin/bwrap` or a sysctl. A copy of `bwrap` elsewhere
  with its own such profile also worked. Claude Code runs the first
  `bwrap` on the `PATH` it inherits, and agent-council runs `claude`
  directly, not through your shell, so a shell alias or function doesn't
  reach agents: put the working `bwrap`'s directory first on `PATH` in
  the environment you run agent-council from.
- **Commands ran unsandboxed** in a check where a socket path under the
  temporary directory exceeded the Unix limit of about 108 bytes.
  agent-council sets each agent's `TMPDIR` and `CLAUDE_CODE_TMPDIR` to a
  scratch directory inside your own temporary directory (from `TMPDIR`,
  `TMP`, or `TEMP`, else `/tmp`), which adds about 36 bytes, so keep
  yours short, e.g. `TMPDIR=/tmp agent-council ...`. A
  `CLAUDE_CODE_TMPDIR` of your own doesn't reach agents.

## Limitations (deliberate)

No retries or timeouts of agent-council's own (the harnesses themselves
may retry transient provider failures), no ranking
or scoring of reports
(beyond the optional consolidator's synthesis), no manifests or indexes —
the directory layout is the index. See [`DESIGN.md`](DESIGN.md) §18–19.

## Stability

This is a 0.x release. The config format, command-line interface, run
directory layout, and report front matter may change incompatibly before 1.0.

## Development

In a git checkout (the gemspec lists files with `git ls-files`),
`./exe/agent-council` and `./exe/pi-models` are equivalent to the installed `agent-council` and
`pi-models`. Agents analyze the working directory, so running
`./exe/agent-council` from the checkout analyzes agent-council itself; to
analyze another project, `cd` there and run the checkout's executable by
its full path. Sample prompts such as `recommend-model-ensemble-prompt.md`
expect `pi-models` on your `PATH`; to use them from a checkout, add its
`exe/` directory (`export PATH="/path/to/agent-council/exe:$PATH"`).

Setup, tests, lint, the pre-commit hook, and the security audit are
described in [`CONTRIBUTING.md`](https://github.com/keithrbennett/agent-council/blob/main/CONTRIBUTING.md)
in the source repository. Before submitting a pull request, open an
issue and wait for explicit approval; `CONTRIBUTING.md` describes the
process.

## Occasional utility: `pi-models`

To choose models yourself, use `pi --list-models` (see
[Discovering and configuring models](#discovering-and-configuring-models)).
The gem also includes `pi-models`, which lists the same kind of
provider/model pairs in forms meant for scripts and agents; the sample
`recommend-model-ensemble-prompt.md` has its agents run it. They differ in
two ways:

- **Output.** `pi --list-models` prints a table for people. `pi-models` prints a table, JSON with pi's model fields
  (`--json`, for `jq`), or one `provider/id` per line (`--ids`, for shell
  loops), and exits non-zero with a clear message if pi is missing or
  fails. `pi-models -h` lists the options and the JSON fields. In a config
  entry (with `harness: pi`), its `provider` is `provider` and its `id`
  is `model`.
- **Source.** `pi-models` asks pi over its RPC interface instead of running
  `pi --list-models`, so its list can include models that
  `pi --list-models` omits (e.g. extra `github-copilot` models), and those
  may not be usable on your account.

`pi-models` requires `pi` and is on your `PATH` once the gem is installed;
like agent-council, it needs WSL on Windows.

[pi-docs]: https://github.com/earendil-works/pi/tree/main/packages/coding-agent/docs
