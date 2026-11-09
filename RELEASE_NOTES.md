# Release Notes

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
