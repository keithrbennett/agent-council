# Release Notes

## 0.4.0 (unreleased)

- **A new command, `agent-council-ps`, shows what a run's agents are
  doing.** Run it in another terminal when an agent is taking longer
  than expected. It lists each running agent-council, then its agents,
  identified by the process IDs it printed, with each agent's harness
  (and model, except for pi), how long it has run, its CPU use, its
  memory, and the commands it is running. `-w` refreshes it until
  Ctrl-C. Runs started directly (including under RVM), from a checkout,
  or with `bundle exec`, under MRI or JRuby, are listed. Each run (and
  `--consolidate`) prints the command, with its process ID, before its
  agents start. See "Seeing what an agent is doing" in
  `RUNAWAY_AGENTS.md`, which also says which runs aren't listed and
  shows a coding assistant diagnosing a slow agent from its output.
- **Agents' process IDs are printed as they start, and several headings
  are renamed.** Each process ID goes on a `- pid` line under a new
  `Started Agents:` heading (or, for the consolidator, under its
  `Consolidation Report` heading), so a running agent can be found, or
  stopped while the others go on: see "Stopping one agent" in
  `RUNAWAY_AGENTS.md`. The lines printed as agents finish, once under
  `Review Progress:`, now come under `Finished Agents:`, and the
  configured agents are listed under `Configured Review Agents (N):`
  and `Configured Consolidator Agent:`, not `Review Agents (N):` and
  `Consolidator Agent:`.
- **A clearer message when a signal stops an agent.** It now reads,
  e.g., `pi was stopped by SIGTERM`, not `pi exited : …`.
- **The lines printed while agents run now show at once when output
  goes to a file or a pipe.** And if the pipe closes (e.g. `| head`),
  the run goes on, discarding the rest of its output, rather than
  ending and leaving its agents running.
- **A fourth harness: OpenCode.** An entry with `harness: opencode` runs
  under the OpenCode CLI (`opencode run`, tested with 1.19.6), with the
  provider and model the entry names and the credentials
  `opencode auth login` saved. Like pi, it reaches many providers, so a
  council can compare a model under both. See "Choosing a harness" in
  the README.
  - OpenCode agents run as an interactive session would: your OpenCode
    config, plugins, and MCP servers apply, and so do the project's
    `AGENTS.md` files and `opencode.json`. Through
    `OPENCODE_CONFIG_CONTENT`, agent-council adds the read-only rules as
    an `instructions` file, denies the edit permission (a default your
    config or the project's can override), lets agents go on after a
    refused tool call, and turns off snapshots; `OPENCODE_DB` keeps each
    agent's session out of your history.
  - Token usage and cost (OpenCode's estimate) are recorded, but
    subagents' usage is missing from them.
  - On Ctrl-C, OpenCode agents don't stop the commands they started
    within the grace period, so those may keep running.
- **The review-latest-commit and review-pull-request sample prompts ask
  agents to keep their test runs light**: the tests relevant to the
  change rather than the whole suite, under one language version or
  interpreter, not several, since several agents run at once on one
  machine.
- **The review-latest-commit sample prompt respects `REVIEW_NOTES.md`.**
  It tells agents not to report what that file, if the repository has
  one, records as an accepted risk or non-issue, unless the
  changes make it worse or its reasoning no longer holds.

## 0.3.0 (2026-11-20)

- **Check before upgrading: agents now get your MCP servers.** Agents in
  every harness get the MCP servers you've configured for it, as an
  interactive session would, instead of none: pi is no longer run with
  `--no-mcp`, and Claude Code no longer with `--strict-mcp-config`. A
  server that writes (posting, commenting, changing tickets) is
  available to every pi agent, held back only by the read-only
  instructions, which now forbid acting outside the machine; Claude
  Code agents run only the MCP tools your settings or the analyzed
  project's allow, and Codex agents only those your config approves,
  since neither can ask. Every agent starts every server it loads, so
  one that acts on startup acts once per agent. Before a run, remove or
  disable servers you don't want agents to have. See "Agents get your
  MCP servers" in the README's Safety section, which also lists which
  servers load (including pi extensions', Claude Code and Codex
  plugins', and Codex's apps connectors) and where to turn each off.
  - pi's tool allowlist gains `codemode` (how pi exposes MCP tools by
    default), `mcp__*` (for servers with direct exposure), `tool_search`
    (for servers with deferred exposure), and pi's MCP resource tools.
    `pi-models` still passes `--no-mcp`.
  - Claude Code agents' refused MCP calls are warnings, as other
    refused calls already were.
- **A third harness: Codex.** An entry with `harness: codex` runs under
  the OpenAI Codex CLI (`codex exec`, tested with 0.167.0), billed
  however your `codex` login is (a ChatGPT plan or an API key). See
  "Choosing a harness" in the README.
  - Codex agents run as an interactive session would: your Codex config
    applies, its `sandbox_mode` included, and so do the project's
    `AGENTS.md` files. `codex exec` never asks for approval, whatever
    your `approval_policy`, so a command that would need it is refused.
    Under Codex's default `read-only` sandbox they get no scratch
    space; under `workspace-write` they can also write the analyzed
    repository (see "Codex's sandbox" in the README).
  - Unlike pi and Claude Code agents, whose built-in tools are limited,
    Codex agents keep Codex's whole built-in toolset, file editing
    included, since Codex can't withhold tools. Its subagent tools fail
    under the `--ephemeral` agent-council passes, so agents can't fan
    out.
  - Codex agents get your MCP servers (see above), but `codex exec` never
    asks for approval, so an MCP tool call is refused unless your config
    approves the tool in advance (e.g. `default_tools_approval_mode =
    "approve"` on the server).
  - Errors Codex reports without failing an agent (such as missing
    metadata for a model name), and failed MCP calls (such as those
    refused for want of approval), are printed as warnings and recorded
    in `run.json`.
  - Codex reports no cost, so a Codex agent's cost is blank, and a run's
    total cost (`total_usage`'s `cost` in `run.json`) is left out when a
    Codex agent reported usage; see the known-cost item below.
  - `mixed-harness.yml` gains a Codex analyst.
- **pi agents can call other models, and those calls are counted.**
  `codemode`, which every pi agent now gets, MCP servers or not, gives
  scripts pi's `models` API (`models.classify`,
  `models.generateImages`), which can send what a script passes it to
  any model pi has credentials for, billed to you. pi agents' usage now
  includes what their tools report. See "pi agents can call other
  models" in the README's Safety section.
- **Runs that mix agents with and without a known cost now show a
  partial cost.** The console summary gives the cost of the analysts
  whose cost is known, leaving out those, such as Codex agents, that
  report none ("$1.00 for the 2 of 3 agents with a known cost"), and
  `run.json` records the same for every entry, consolidations included,
  as `known_cost` and `known_cost_runs`.
- **The scaffolding now tells agents not to act outside the machine**:
  not to post, comment, send messages, or change remote data with any
  tool, MCP tools included. Reading remote
  information is still allowed.

## 0.2.0 (2026-11-19)

- **A new option, `--gem-dir`, prints the root directory of the
  agent-council application and exits.** That directory holds its
  documentation and examples.
- **A new option, `--project-url`, prints the project's GitHub URL and
  exits.**
- **The sample code-review ensemble is removed.** Model offerings change
  too often to keep `code-review-agents.md` current. To get a current
  recommendation, run `examples/prompts/recommend-model-ensemble-prompt.md`.
- **A new catalog of use cases.** `USE_CASES.md` lists what
  agent-council can be used for, and the README gains a "What makes a
  good fit" section.
- **Costs are now described as estimates, not what you're billed.** For
  pi agents, they come from pi's price table. A new README section, "How
  far to trust the cost", says why they can be far off: subscription
  pricing, price tables, stopped agents recording no usage, and token
  counting.
- **A new README section, "Claude Code's sandbox".** It covers
  Claude Code's own Bash sandbox, which Claude Code's settings turn on,
  and which the analyzed repository's settings can turn on or off: it
  leaves the repository writable, commands in
  `sandbox.excludedCommands` run outside it, an agent's request to run
  a command outside it was refused in a check, and agent-council
  doesn't notice other sandbox trouble. On Linux, a `bwrap` blocked by
  AppArmor makes every command fail (an alias can't fix it for agents),
  and a `TMPDIR` too long for the sandbox to start leaves commands
  unsandboxed by default.
- **Agents are told to use `$TMPDIR` for scratch space, not the scratch
  directory's path, which Claude Code's sandbox makes read-only.**
  Under that sandbox, `$TMPDIR` is a writable directory inside the
  scratch directory; elsewhere, it is the scratch directory itself. The
  scaffolding is now identical for every agent. agent-council also sets
  each agent's `CLAUDE_CODE_TMPDIR` to its scratch directory, so the
  sandbox's `$TMPDIR` stays inside it, whatever your own setting.
- **Two sample prompts no longer tell agents to write a report file
  into the project, and one no longer compares with earlier reports.**
  Like the other samples, the state-of-the-codebase and
  test-coverage-analysis prompts now have agents deliver their report
  as the final message, which agent-council saves. The comparison with
  earlier reports is dropped from the state-of-the-codebase prompt.
- **pi is now run with `--no-mcp`, both for agents and by
  `pi-models`.** The MCP servers configured for pi's built-in MCP
  support therefore no longer start. Their tools were already
  unavailable to agents; a server that did something merely by starting
  no longer does it. An extension that provides its own MCP support
  isn't affected. This requires pi 1.0.4 or later.
- **The test-coverage-analysis sample prompt uses only the cov-loupe
  CLI**, since agents have no MCP tools.
- **A second harness: Claude Code.** Agents and the consolidator can run
  under Claude Code, alongside pi agents in the same config: each
  entry's `harness` value names its harness, `pi` or `claude`, and an
  unknown name is rejected at startup (with `--consolidate`, only the
  consolidator's, since no analysts run). A Claude Code entry's
  `provider` only labels the agent. Claude Code agents bill however
  `claude` does at your terminal, to a subscription login or an API key;
  agent-council sets nothing for billing. Of Claude Code's built-in
  tools, agents get only `Read`, `Grep`, `Glob`, and `Bash`; they get no
  MCP servers, and they load `CLAUDE.md`, settings, hooks, plugins, and
  auto memory as an interactive session would, including the analyzed
  repository's own hooks. A tool call Claude Code refuses (e.g. under a
  `permissions.deny` rule) is reported as a warning, also shown in the
  report's metadata table (where the consolidator sees it) and recorded
  in `run.json`; the report is kept, and an agent that fails anyway
  still gets the warning. Only configs that use Claude Code need the
  `claude` CLI.
- **Breaking: a 0.1.0 config needs `harness: pi` added to each
  entry.** Every agent and consolidator entry must give `harness`,
  `provider`, and `model`; there are no defaults. To `--consolidate` a
  run made by 0.1.0, add `harness: pi` to the consolidator in the run's
  config copy; its reports and `run.json` are still read as pi's.
- **Config errors are all reported at once.** They list every bad entry,
  each named by its key (e.g. `'agents' entry #2` or `'consolidator'`)
  with every problem it has (missing or blank keys, values that aren't
  strings, an unknown harness), and say what a misshapen `agents` list
  or entry is instead (e.g. a consolidator given as a list).
- **The startup header shows the working directory.** The header of a
  run and of `--consolidate` now begins with a `Working Dir:` line, and
  the relative paths after it are shown against that directory. The
  labels after it are realigned to match.
- **A new guide to runaway agents.** agent-council has no time limit,
  and `RUNAWAY_AGENTS.md` explains why there isn't a built-in one yet
  and how to limit a whole run with the `timeout` command (with a shell
  function that wraps it), including its pitfalls: Ctrl-C needs
  `--foreground`, a limit that runs out too soon throws away work, and
  whether time asleep counts depends on the `timeout` you have.
- **The README shows what a run prints.** A new section, "What a run
  prints", gives a sample run's console output.
- **The review-latest-commit sample prompt has agents begin their
  report with the full hash and subject of the commit reviewed.**
- **"Run" now means only a whole agent-council run.** The docs and
  messages use "agent" for one agent's part in it; e.g. a failure now
  reads "… exited 0 but the agent failed". `run.json` is unchanged.

## 0.1.0 (2026-11-09)

Initial release. agent-council runs one prompt through several AI coding
agents on your project, using the pi harness with any mix of providers and
models, and gives you a consolidated report of what they found plus a
head-to-head comparison of the agents.

### What a run produces

- **A consolidated findings report** (`*_findings.md`): consensus findings,
  unique findings, and contradictions across the agents, ready to paste
  into an AI chat.
- **A companion meta report** (`*_meta.md`): the run's metadata and an
  assessment of each agent's work, with its duration, token usage, and
  cost.
- **Each agent's own report**, as a separate Markdown file showing its
  duration and usage.
- **`run.json`**, recording every agent run's outcome, duration, token
  usage, and, where the harness can price it, cost.

The console shows token usage per agent and in total.

### Usage

- **Runs go under `./agent-council-reports`**, or under the directory
  given with `-o` / `--output-dir`.
- **`--consolidate RUN_DIR`** runs just the consolidation of a finished
  run, writing into that run directory.
- **`AGENT_COUNCIL_OPTS`** holds arguments inserted before the
  command-line ones.
- **Sample prompts and configs** are included under `examples/`.
- **The `pi-models` helper** lists the provider/model pairs available to
  pi.

### Safety

agent-council does not sandbox the agents: they get pi's `bash` tool,
running as you. See [Safety and privacy](README.md#safety-and-privacy) in
the README before running it.

### Requirements

- **Ruby 3.3 or later, or JRuby 10 or later** (where SIGQUIT is left to
  the JVM, so it doesn't stop a run).
- **The [pi](https://github.com/earendil-works/pi) CLI.**
- **Native Windows is not supported**; on Windows, run agent-council
  inside WSL.

Install with `gem install agent-council`. New to Ruby? See
[Install agent-council from scratch](INSTALL.md).
