# Release Notes

## 0.2.0 (unreleased)

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
  price tables, stopped runs recording no usage, and token counting.
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
  (with `--consolidate`, only the consolidator's, since no analysts
  run). A Claude Code entry's `provider` only labels the run. Runs bill
  however `claude` does at your terminal, to a subscription login or an
  API key; agent-council sets nothing for billing. Of Claude Code's
  built-in tools, agents get only `Read`, `Grep`, `Glob`, and `Bash`;
  they get no MCP servers, and they load `CLAUDE.md`, settings, hooks,
  plugins, and auto memory as an interactive session would, including
  the analyzed repository's own hooks. A tool call Claude Code refuses
  (e.g. under a `permissions.deny` rule) is reported as a warning, also
  shown in the report's metadata table (where the consolidator sees it)
  and recorded in `run.json`; the report is kept, and a run that fails
  anyway still gets the warning. Only configs that use Claude Code need
  the `claude` CLI.
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
