# Recommend a Model Ensemble

Discover the available provider/model entries with `pi-models --json`, then
recommend a small ensemble for the user's task and constraints.

## Inputs

- **Task:** [Describe the task, such as code review]
- **Number of agents:** [How many recommendations to make]
- **Priorities:** [For example: insightful findings, speed, cost, provider diversity]
- **Unavailable providers or models:** [List any that do not work]
- **Current config:** [Optional existing `agents:` / `consolidator:` YAML]
- **Other constraints:** [Optional]

## Instructions

1. Run `pi-models --json` to discover the provider/model entries in the pi
   catalog. Use this as the source for model names and listed attributes, but
   do not assume every entry is authenticated or covered by the user's plan.
   Exclude any providers or models the user marked unavailable. If the command
   is not installed or fails, say so and ask the user to provide the model
   list; do not invent available models.
2. Recommend exactly the requested number of agents and one consolidator,
   choosing only from the discovered list. If a current config is provided,
   use it as the baseline and explain any meaningful changes.
3. Optimize the full ensemble for the stated priorities. When provider
   diversity matters, spread
   recommendations across distinct provider routes where practical. Prefer
   different underlying model families too, since multiple routes to the same
   model may provide less useful independent feedback.
4. Balance capability with speed. A useful ensemble can combine a strong
   primary reviewer, a fast broad pass, and one or more independent deep or
   critical reviews. Avoid making every selection a slow, heavyweight model.
5. Assign each recommendation a clear role and briefly explain why it fits.
   Note meaningful tradeoffs, such as a slower model reserved for consequential
   changes.
6. Do not infer subscription quotas, actual latency, or cost from provider
   names alone. State when a recommendation depends on an assumption about the
   user's subscriptions or plan limits.
7. If browsing is available and current capability claims affect the choice,
   verify them with reliable, preferably primary sources. Cite factual claims
   near where they appear. Separate source-backed claims from judgment based on
   the user's priorities. If browsing is unavailable, say that the ranking is
   based on the discovered catalog and general model-family knowledge.
8. Keep the result concise and actionable. Use a table with provider, model,
   and role/reason for each agent and the consolidator, followed by a short
   explanation of the overall mix.
9. End with a fenced `yaml` code block containing a ready-to-copy config with
   this shape:

   ```yaml
   agents:
     - provider: ...
       model: ...
   consolidator:
     provider: ...
     model: ...
   ```

   Ensure every provider/model pair in the YAML appears in the discovered
   catalog and preserve the requested number of agent entries.

## Example result

See [Four agents for code review](../results/recommend-model-ensemble-code-review.md)
for an example recommendation produced from a model list and the priorities
of provider diversity, useful code-review findings, and reasonable speed.
(That file is generated output kept in the source repository only; it is
not included in the gem.)
