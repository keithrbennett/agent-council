# Release Notes

## 0.1.0 (unreleased)

Initial release: run one prompt through multiple models via the pi harness,
saving each model's final response as a Markdown report, with optional
consolidation by another model. `--consolidate RUN_DIR` reruns just the
consolidation of a finished run. Reports go under `./agent-council-reports`,
or under the directory given with `-o` / `--output-dir`. Includes sample
prompts and configs under `examples/`.

Runs on Ruby 3.2 or later and on JRuby 10 or later (where SIGQUIT is left
to the JVM, so it doesn't stop a run). Native Windows is not supported; on
Windows, run agent-council inside WSL.
