# Four agents and a consolidator for code review

| Role | Provider | Model | Why it fits |
|---|---|---|---|
| Main reviewer | **openai-codex** | **GPT-6 Sol** | Strong coding and reasoning choice for the primary review. OpenAI reports it matching Claude Fable 5.1 xhigh on its FrontierCode evaluation. ([Source](https://openai.com/index/introducing-gpt-6-sol-and-luna/)) |
| Fast first pass | **github-copilot** | **Gemini 3.8 Flash** | Scans for bugs and missed edge cases. Google describes it as a coding and reasoning upgrade at the same speed as Gemini 3.7 Flash. ([Source](https://blog.google/innovation-and-ai/models-and-research/gemini-models/3-8-flash-and-3-8-flash-cyber/)) Aggregator benchmarks put it ahead of Gemini 3.1 Pro on coding indexes, so a Pro-tier model is not needed here. ([Source](https://serenitiesai.com/benchmark/compare/gemini-3-1-pro-vs-gemini-3-8-flash)) |
| Deep reviewer | **opencode-go** | **DeepSeek V4 Pro** | Independent review for complex changes; supports high reasoning effort for agent workflows. ([Source](https://api-docs.deepseek.com/news/news260813/)) |
| Critical reviewer | **cursor** | **Claude Opus 5.5 High** | Careful final critique. Cursor describes it as frontier intelligence and recommends High thinking for best results. ([Source](https://prod.cursor.com/docs/models/claude-opus-5-5)) |
| Consolidator | **openai-codex** | **GPT-6 Astra** | Synthesizes the findings using a strong reasoning model on a provider route already used by the ensemble. |

This uses four provider routes across four distinct agent model families. Opus 5.5 is the heavier review pass, so reserve it for consequential changes; the consolidator compares findings and highlights agreement, conflicts, and the most actionable issues.


## Notes on Gemini access

- **No Gemini subscription login in pi.** Pi removed its built-in Google Gemini CLI and Antigravity logins, and users reported account bans from using Google consumer logins in third-party tools. ([Source](https://deepakness.com/raw/antigravity-omp-bans/)) Google also deprecated consumer Gemini Code Assist access (including Google AI Pro) on June 18, 2026. ([Source](https://syntackle.com/blog/google-gemini-ai-subscription-with-opencode/)) Community login extensions exist but carry the same risk.
- **Supported routes:** a Gemini API key (`GEMINI_API_KEY`, pay per use), or Gemini models offered through another plan. This example uses GitHub Copilot's Flash-tier Gemini to keep Cursor usage to a single model; `cursor` also lists Gemini models (including `gemini-3.8-flash-high`) if Copilot's quota is too tight.
- **Verify before relying on it.** `pi auth check` may report a Cursor provider as not ready even when `cursor-agent` is logged in. Run one real prompt through each entry first.

```yaml
agents:
  - provider: openai-codex
    model: gpt-6-sol
  - provider: github-copilot
    model: gemini-3.8-flash
  - provider: opencode-go
    model: deepseek-v4-pro
  - provider: cursor
    model: claude-opus-5-5-high
consolidator:
  provider: openai-codex
  model: gpt-6-astra
```
