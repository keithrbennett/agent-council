# Release Notes

## 0.1.0 (unreleased)

Initial release: run one prompt through multiple models via the pi harness,
saving each model's final response as a Markdown report, with optional
consolidation by another model. `--consolidate RUN_DIR` runs just the
consolidation of a finished run. Runs go under `./agent-council-reports`,
or under the directory given with `-o` / `--output-dir`; `--consolidate`
writes into the run directory it is given. `AGENT_COUNCIL_OPTS`
can set default options, currently only `--output-dir`. Includes
sample prompts and configs under `examples/`, and a `pi-models` helper that
lists the provider/model pairs available to pi.

agent-council does not sandbox the agents: they get pi's `bash` tool,
running as you. See [Safety and privacy](README.md#safety-and-privacy) in the README before running it.

Runs on Ruby 3.2 or later and on JRuby 10 or later (where SIGQUIT is left
to the JVM, so it doesn't stop a run). Native Windows is not supported; on
Windows, run agent-council inside WSL.
