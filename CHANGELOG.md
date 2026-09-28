# Changelog

## Unreleased

- Initial release: run one prompt through multiple pi harness models, with optional consolidation.
- Prompt files may end in `-prompt.md` as well as `_prompt.md`; either suffix is stripped from the report slug.
- Reports go in `untracked/reports` instead of `reports` when the working directory has an `untracked/` directory.
- Default config is no longer shipped with the gem: omitting `CONFIG_FILE` uses `./agent-council.yml` in the current directory if present, else `~/.agent-council.yml`, and otherwise aborts with a message pointing to `examples/configs/`.
- Prompt templates moved from `prompts/` to `lib/agent_council/templates/`; the gem now packages only `lib/`, `exe/`, and README/CHANGELOG/LICENSE.
