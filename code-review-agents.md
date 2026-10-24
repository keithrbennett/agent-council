# Four agents and a consolidator for code review

| Role | Provider | Model | Why it fits |
|---|---|---|---|
| Main reviewer | `cursor` | `claude-opus-5-5-medium` | Primary review pass. |
| Fast first pass | `openai` | `gpt-6.1-sol` | Scans for bugs and missed edge cases. |
| Deep reviewer | `deepseek` | `deepseek-flash` | Independent review for complex changes. |
| Critical reviewer | `cursor` | `gemini-3.8-flash-high` | Careful final critique. |
| Consolidator | `cursor` | `claude-sonnet-5-5-high` | Synthesizes the findings. |

This uses three provider routes across four distinct agent model families. Opus 5.5 is the heavier review pass, so reserve it for consequential changes; the consolidator compares findings and highlights agreement, conflicts, and the most actionable issues.

To use it, copy the YAML block below into your config (`agent-council.yml` or `~/.agent-council.yml`), replacing any provider or model you don't have access to (see `pi --list-models`).

```yaml
agents:
  - provider: cursor
    model: claude-opus-5-5-medium
  - provider: openai
    model: gpt-6.1-sol
  - provider: deepseek
    model: deepseek-flash
  - provider: cursor
    model: gemini-3.8-flash-high
consolidator:
  provider: cursor
  model: claude-sonnet-5-5-high
```
