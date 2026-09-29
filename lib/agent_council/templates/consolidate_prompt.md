# Consolidation task

You are consolidating several independent analyses of the same repository.
Every analyst received the identical prompt (included below as "Original
prompt"). Their reports follow under "Analyst reports", each headed by the
model that produced it.

Produce a consolidated report with exactly these sections:

## Agent Consultants

A list of provider/model agents consulted; for any that failed to run properly,
say so and say why.

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

## Explain Findings, Don't Just List Them

When listing findings, unanimous or otherwise, add enough explanation of the issue so that the reader
can easily understand what the issue is. Avoid limiting the text to single phrase attributions.

## Overall assessment

The most important findings overall and your confidence in each. If you can
verify a claim against the repository, do so (read-only) and state the
result.

Rules:
- Begin directly with the "## Agent Consultants" section; do not add a
  document title or top-level heading.
- Attribute every claim to its source model(s); never drop attribution.
- Do not invent findings that appear in no report.
- Deduplicate, but do not dilute: keep concrete file and line references.
