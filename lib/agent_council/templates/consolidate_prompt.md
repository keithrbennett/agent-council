# Consolidation task

You are consolidating several independent analyses of the same repository.
Every analyst received the identical prompt (included below as "Original
prompt"), followed by formatting instructions for its report. Their reports follow under "Analyst reports", each headed "Report
from" its source label (`#<agent number> <provider> / <model>`). Agents that produced no report are listed last,
under "Agents without a report", each with the reason shown there (its
failure, when known).

Produce a consolidated report with exactly these sections:

## Agent Consultants

A list of provider/model agents consulted. For each agent listed under
"Agents without a report", say it produced no report and give the reason
shown there; do not infer failures any other way. If a report shows its
agent could not properly do the task, say so too.

## Findings

- Output the findings of each section (consolidated or unique) in a _numbered_ list.
- For each finding, add explanatory text if it would be helpful to the reader.

### Consensus findings

Issues identified independently by two or more analysts. 

For each, list the sources and briefly note any differences in emphasis.

### Unique findings

Issues raised by exactly one analyst, attributed to its source. 

- Assess whether each is plausible.
- Group findings by agent; for each group:
  - output a heading with the agent number, provider, and model name
 
## Contradictions

Points where analysts disagree, with each position attributed.

## Overall assessment

The most important findings overall and your confidence in each. If you can
verify a claim against the repository, do so (read-only) and state the
result.

Rules:
- Begin directly with the "## Agent Consultants" section; do not add a
  document title or top-level heading.
- Attribute every claim to its source model(s); never drop attribution.
- Explain findings, don't just list them: when listing findings, unanimous
  or otherwise, add enough explanation that the reader can easily
  understand what the issue is. Avoid limiting the text to single-phrase
  attributions.
- Do not invent findings that appear in no report.
- Deduplicate, but do not dilute: keep concrete file and line references.
