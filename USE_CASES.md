# agent-council: Use Cases

A catalog of what agent-council can be used for. For what it is and
what it produces, see the start of the [README](README.md); for why
to use it, [Why use it](README.md#why-use-it); and for how to tell
whether a task suits it, [What makes a good
fit](README.md#what-makes-a-good-fit).

Where a sample prompt exists, it's linked; the samples are in
`examples/prompts/`, which is included in the installed gem.

## Code review

- The latest commit plus uncommitted changes, before pushing
  ([`review-latest-commit-prompt.md`](examples/prompts/review-latest-commit-prompt.md),
  which lets agents run tests and linters).
- A GitHub pull request, with its unaddressed comments and failing checks
  ([`review-pull-request-prompt.md`](examples/prompts/review-pull-request-prompt.md)),
  whether you're its reviewer, its author, the project's maintainer, or
  an outsider reviewing a PR in someone else's project
  ([`dnsruby-pull-221-prompt.md`](examples/prompts/dnsruby-pull-221-prompt.md)
  is a one-line example).
- A feature branch, or a range of commits, as a whole.
- High-stakes changes: security-sensitive code, concurrency, migrations,
  money, public APIs, and large dependency upgrades.
- Re-reviews after fixes, comparing the new run's reports with the old.

## Understanding a codebase

- Onboarding to a project you've joined or inherited.
- State-of-the-codebase assessments, before planning, after a refactoring,
  or periodically to track health over time
  ([`state-of-the-code-base-prompt.md`](examples/prompts/state-of-the-code-base-prompt.md)).
- Due diligence on a library, fork, or acquisition before adopting it
  (in a sandbox; see the README's [Safety and
  privacy](README.md#safety-and-privacy)).
- Specific questions about how something works ("what happens when the
  cache is unavailable?"), where agreement builds confidence and
  disagreement shows where to look.
- A first draft of missing architecture documentation.

## Decisions and design

- The best way to fix a bug or build a feature, with alternatives and
  trade-offs.
- Naming, defaults, flags versus config settings, file formats, and other
  design choices where one model's confident answer can mislead
  ([`project-name-prompt.md`](examples/prompts/project-name-prompt.md)
  asks for project names).
- Release readiness: "Is this ready to publish?", "What would stop
  someone else from using this?"
- Open-ended "what are we missing?" questions, where each model's blind
  spots differ.
- Migration and upgrade planning, and what will break.
- Comparing competing proposals neutrally, to settle or sharpen a team
  debate.

## Debugging

- Ranked hypotheses for a hard bug from its symptoms, with how to
  confirm each (or confirmation itself, if the prompt permits tests).
- Post-incident analysis: how a defect got in and why it wasn't caught.
- Candidate mechanisms for flaky tests.

## Quality audits

- Documentation against the code
  ([`review-docs-prompt.md`](examples/prompts/review-docs-prompt.md)).
- Test coverage gaps, ranked by risk, with a fix prompt for each
  ([`test-coverage-analysis-prompt.md`](examples/prompts/test-coverage-analysis-prompt.md)).
- Security, error handling, performance, dependencies and licenses,
  portability, consistency, dead code, logging, accessibility, and
  internationalization.

## Planning

- A prioritized backlog from a council's findings.
- Ready-to-use prompts or tickets for each recommendation, to hand to a
  coding agent.
- Scoping a feature: what it touches, and its risks.
- "What should we work on next?"

## Beyond source code

- Infrastructure and configuration: Terraform, Kubernetes, Dockerfiles,
  and CI workflows (agents inherit your shell's credentials, so keep
  production out of reach).
- Documentation sets, manuscripts, and other writing, where models'
  tastes differ and a council shows which criticisms are robust.
- Specifications and requirements, for ambiguity and missing cases.
- Data, notebooks, and analysis scripts, for methodological problems.
- Prompts needing no files: names, taglines, ideas, and general
  questions.

## Choosing models and providers

The README's [A benchmark built from your own
work](README.md#a-benchmark-built-from-your-own-work) and [What you
get](README.md#what-you-get) describe what's measured and where it's
saved.

- Picking a default model, from weeks of `run.json` files from real work.
- Picking an ensemble: which models find things the others don't.
- Recommending a provider-diverse ensemble for a task
  ([`recommend-model-ensemble-prompt.md`](examples/prompts/recommend-model-ensemble-prompt.md)).
- Whether a premium model is worth its price for a given kind of task.
- Trying a new model on your real work when it's released.
- Catching regressions by rerunning a saved prompt after a model update.
- Measuring one model's consistency by configuring it several times.
- Comparing providers serving the same model, on latency, price, and
  reliability.
- Finding out which listed models your plan actually covers.

## Prompts and consolidation

- Testing a reusable prompt for robustness across models before sharing
  it.
- Seeing how sensitive models are to a change of wording.
- Trying other consolidator models on a finished run with
  `--consolidate`, without paying for the agents again, or, in a source
  checkout, edited consolidation instructions.

## Learning, teams, and automation

- Learning how models reason, and where their output can and can't be
  trusted, from their contradictions.
- A team's shared library of prompts and configs.
- Evidence for decisions about which AI providers and models to pay for.
- Pasting a findings file into a chat, ticket, or coding agent as is.
- Batch and scheduled runs across many repositories or prompts (see the
  README's [Running](README.md#running) for `AGENT_COUNCIL_OPTS` and
  [What you get](README.md#what-you-get) for exit status; there are no
  timeouts, so watch unattended runs).
