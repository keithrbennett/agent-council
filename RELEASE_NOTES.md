# Release Notes

## 0.3.0 (unreleased)

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
- A third harness: an entry with `harness: codex` runs under the OpenAI
  Codex CLI (`codex exec`, tested with 0.167.0), billed however your
  `codex` login is (a ChatGPT plan or an API key). See "Choosing a
  harness" in the README.
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
- `codemode`, which every pi agent now gets, MCP servers or not, gives
  scripts pi's `models` API (`models.classify`,
  `models.generateImages`), which can send what a script passes it to
  any model pi has credentials for, billed to you. pi agents' usage now
  includes what their tools report, so such calls are counted. See "pi
  agents can call other models" in the README's Safety section.
- A run that mixes agents with and without a known cost (such as Codex
  agents, which have none) now shows the cost of the analysts whose
  cost is known in the console summary ("$1.00 for the 2 of 3 agents
  with a known cost"), and `run.json` records the same for every entry,
  consolidations included, as `known_cost` and `known_cost_runs`.
- The scaffolding gains a rule: agents must not act outside the machine
  (post, comment, send messages, or change remote data) with any tool,
  MCP tools included. Reading remote information is still allowed.

## 0.2.0 (2026-11-19)

- `--gem-dir` prints the root directory of the agent-council application,
  which holds its documentation and examples, and exits.
- `--project-url` prints the project's GitHub URL and exits.
- `code-review-agents.md`, a sample code-review ensemble, is removed;
  model offerings change too often to keep it current. To get a current
  recommendation, run `examples/prompts/recommend-model-ensemble-prompt.md`.
- `USE_CASES.md`, a catalog of what agent-council can be used for, is
  added, and the README gains a "What makes a good fit" section.
- Costs are now described as estimates (for pi agents, from pi's price
  table), not what you're billed. A new README section, "How far to
  trust the cost", says why they can be far off: subscription pricing,
  price tables, stopped agents recording no usage, and token counting.
- A README section, "Claude Code's sandbox", covers Claude Code's own
  Bash sandbox, which Claude Code's settings turn on, and which the
  analyzed repository's settings can turn on or off: it leaves the
  repository writable, commands in `sandbox.excludedCommands` run
  outside it, an agent's request to run a command outside it was refused
  in a check, and agent-council doesn't notice other sandbox trouble. On
  Linux, a `bwrap` blocked by AppArmor makes every command fail (an
  alias can't fix it for agents), and a `TMPDIR` too long for the
  sandbox to start leaves commands unsandboxed by default.
- The scaffolding tells agents to use `$TMPDIR` for scratch space
  instead of giving the scratch directory's path, which Claude Code's
  sandbox makes read-only (`$TMPDIR` is a writable directory inside it).
  The scaffolding is now identical for every agent. agent-council also
  sets each agent's `CLAUDE_CODE_TMPDIR` to its scratch directory, so
  the sandbox's `$TMPDIR` stays inside it, whatever your own setting.
- The state-of-the-codebase and test-coverage-analysis sample prompts
  no longer tell agents to write their report to a file in the project;
  like the other samples, they deliver it as the final message, which
  agent-council saves. The state-of-the-codebase prompt no longer
  compares with earlier reports.
- pi is now run with `--no-mcp`, both for agents and by `pi-models`, so
  the MCP servers configured for pi's built-in MCP support no longer
  start. Their tools were already unavailable to agents; a server that
  did something merely by starting no longer does it. An extension that
  provides its own MCP support isn't affected. This requires pi 1.0.4 or
  later.
- The test-coverage-analysis sample prompt uses only the cov-loupe CLI,
  since agents have no MCP tools.
- Agents and the consolidator can run under Claude Code, alongside pi
  agents in the same config: each entry's `harness` value names its
  harness, `pi` or `claude`, and an unknown name is rejected at startup
  (with `--consolidate`, only the consolidator's, since no analysts run).
  A Claude Code entry's `provider` only labels the agent. Claude Code
  agents bill however `claude` does at your terminal, to a subscription
  login or an API key; agent-council sets nothing for billing. Of Claude
  Code's built-in tools, agents get only `Read`, `Grep`, `Glob`, and
  `Bash`; they get no MCP servers, and they load `CLAUDE.md`, settings,
  hooks, plugins, and auto memory as an interactive session would,
  including the analyzed repository's own hooks. A tool call Claude Code
  refuses (e.g. under a `permissions.deny` rule) is reported as a warning,
  also shown in the report's metadata table (where the consolidator sees
  it) and recorded in `run.json`; the report is kept, and an agent that
  fails anyway still gets the warning. Only configs that use Claude Code
  need the `claude` CLI.
- **Breaking:** every agent and consolidator entry must give `harness`,
  `provider`, and `model`; there are no defaults. To update a 0.1.0
  config, add `harness: pi` to each entry. To `--consolidate` a run made
  by 0.1.0, add `harness: pi` to the consolidator in the run's config
  copy; its reports and `run.json` are still read as pi's.
- Config errors list every bad entry at once, each named by its key
  (e.g. `'agents' entry #2` or `'consolidator'`) with every problem it
  has (missing or blank keys, values that aren't strings, an unknown
  harness), and say what a misshapen `agents` list or entry is instead
  (e.g. a consolidator given as a list).
- The startup header of a run and of `--consolidate` now begins with a
  `Working Dir:` line giving the working directory, which the relative
  paths after it are shown against. The labels after it are realigned to
  match.
- `RUNAWAY_AGENTS.md` is added. agent-council has no time limit, and
  this explains why there isn't a built-in one yet and how to limit a
  whole run with the `timeout` command (with a shell function that
  wraps it), including its pitfalls: Ctrl-C needs `--foreground`, a
  limit that runs out too soon throws away work, and whether time asleep
  counts depends on the `timeout` you have.
- The README shows a sample run's console output, in a new "What a run
  prints" section.
- The review-latest-commit sample prompt has agents begin their report
  with the full hash and subject of the commit reviewed.
- The docs and messages use "run" only for a whole agent-council run,
  and "agent" for one agent's part in it; e.g. a failure now reads
  "… exited 0 but the agent failed". `run.json` is unchanged.

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

- Runs go under `./agent-council-reports`, or under the directory given
  with `-o` / `--output-dir`.
- `--consolidate RUN_DIR` runs just the consolidation of a finished run,
  writing into that run directory.
- `AGENT_COUNCIL_OPTS` holds arguments inserted before the command-line
  ones.
- Sample prompts and configs are included under `examples/`.
- The `pi-models` helper lists the provider/model pairs available to pi.

### Safety

agent-council does not sandbox the agents: they get pi's `bash` tool,
running as you. See [Safety and privacy](README.md#safety-and-privacy) in
the README before running it.

### Requirements

- Ruby 3.3 or later, or JRuby 10 or later (where SIGQUIT is left to the
  JVM, so it doesn't stop a run).
- The [pi](https://github.com/earendil-works/pi) CLI.
- Native Windows is not supported; on Windows, run agent-council inside
  WSL.

Install with `gem install agent-council`. New to Ruby? See
[Install agent-council from scratch](INSTALL.md).
