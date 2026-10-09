# Four agents and a consolidator for code review

| Role | Provider | Model | Why it fits |
|---|---|---|---|
| Main reviewer | **cursor** | **Claude Opus 5.5 Thinking Medium** | Primary review pass. |
| Fast first pass | **openai-codex** | **GPT-6.1 Sol** | Scans for bugs and missed edge cases. |
| Deep reviewer | **deepseek** | **DeepSeek Flash** | Independent review for complex changes. |
| Critical reviewer | **cursor** | **Gemini 3.8 Flash High** | Careful final critique. |
| Consolidator | **cursor** | **Claude Sonnet 5.5 Thinking High** | Synthesizes the findings. |

This uses three provider routes across four distinct agent model families. Opus 5.5 is the heavier review pass, so reserve it for consequential changes; the consolidator compares findings and highlights agreement, conflicts, and the most actionable issues.

```yaml
agents:
  - provider: cursor
    model: claude-opus-5.5-thinking-medium
  - provider: openai-codex
    model: gpt-6.1-sol
  - provider: deepseek
    model: deepseek-flash
  - provider: cursor
    model: gemini-3.8-flash-high
consolidator:
  provider: cursor
  model: claude-sonnet-5.5-thinking-high
```
