# Task: Replace gem-shipped default config with cwd convention

## Context

`agent-council` currently defaults `CONFIG_FILE` to a config shipped inside the gem at `lib/agent_council/templates/consolidated.yml` (the `DEFAULT_CONFIG` constant in `lib/agent_council.rb`). The config is user configuration (providers, models, optional consolidator), not code, and should not live in `lib/` or be shipped with the gem.

The prompt templates (`lib/agent_council/templates/consolidate_prompt.md` and `lib/agent_council/templates/analyst_format.md`) are code-like runtime data and stay where they are — do not move them.

## What to change

1. **Remove the default config concept from the gem:**
   - Delete the `DEFAULT_CONFIG` constant from `lib/agent_council.rb`.
   - Delete `lib/agent_council/templates/consolidated.yml`.
   - `examples/configs/consolidated.yml` should be a real file with the same content, as a pure, non-runtime sample (the `examples/` directory is never shipped in the gem).

2. **New config resolution rule** in `AgentCouncil.main`:
   - If the positional `CONFIG_FILE` argument is given, use it (unchanged).
   - Else, if a file named `agent-council.yml` exists in the current working directory, use it.
   - Else, abort with a helpful message, e.g.:
     ```
     No config file given and no agent-council.yml found in the current directory.
     Pass a config path: agent-council PROMPT_FILE CONFIG_FILE
     See examples/configs/ in the repository for sample configs.
     ```
   - Only the cwd is checked — no upward directory walk. This matches how `reports_dir` already treats the cwd.

3. **Update `option_parser` help banner:** change the `CONFIG_FILE` argument line to document the new rule, e.g.:
   ```
   CONFIG_FILE   Path to a YAML agent config (default: ./agent-council.yml if present)
   ```

4. **Update `exe/agent-council` header comment** to describe the new rule.

5. **Update `README.md`:**
   - Replace references to `lib/agent_council/templates/consolidated.yml` as the default config with the `agent-council.yml` convention.
   - Update the "Running" examples so the zero-arg form notes that it requires `./agent-council.yml` to exist.
   - Keep `examples/configs/` described as pure, non-runtime samples.
   - Remove the note about `examples/configs/consolidated.yml` being a symlink.

6. **Update `DESIGN.md`** repository-layout section: remove `consolidated.yml` from the `lib/agent_council/templates/` listing, and restore `examples/configs/consolidated.yml` as a plain file (remove the "symlink" annotation).

## Verification

- `rspec` passes (update specs if any reference `DEFAULT_CONFIG`; add a spec for the new resolution rule if the existing test structure makes that practical).
- `ruby exe/agent-council -h` shows the updated CONFIG_FILE line.
- Running with no config in a directory without `agent-council.yml` produces the new abort message.
- Sanity-check that `YAML.safe_load_file` and the `FileUtils.cp(config_path, run_dir)` step work unchanged with the new resolution (they should — only the path selection changes).
- Do NOT run the CLI against real models; the unit tests and help output are sufficient.

## Constraints

- Do not move or rename the prompt templates.
- Do not change the gemspec's file glob (it no longer needs to match any config; templates stay under `lib/` which is already globbed).
- Keep the change minimal — no unrelated refactors.
