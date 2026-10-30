# Review Pull Request

Review the GitHub pull request for the branch checked out in the current
working directory. Report only issues needing addressing.

The user has checked out the PR's head branch (for example with
`gh pr checkout <number>`) before starting this run. Use the local checkout
for reading and searching code; use the `gh` CLI only for what exists only
on GitHub.

## Gathering the PR

- Run `gh pr view --json number,title,body,author,baseRefName,headRefName,headRefOid,files,reviewDecision,statusCheckRollup`
  for the PR's metadata, and `gh pr view --comments` for its discussion.
  Read inline review threads with
  `gh api repos/{owner}/{repo}/pulls/<number>/comments`.
- Take the PR's changes from `gh pr diff`; it is authoritative even if the
  local base branch is stale.
- Compare `git rev-parse HEAD` with `headRefOid`. If they differ, or there
  are uncommitted changes, say so at the top of the report: local files may
  not match the PR.
- If `gh` is missing, unauthenticated, or finds no PR for this branch, don't
  review: report only that, with the command and its error. Reach GitHub
  only through `gh`: no `curl`, `wget`, or other HTTP client against the API
  or web pages, which unauthenticated allows only 60 requests an hour,
  shared by all concurrent agents.
- Do not run `gh pr checkout`, `git fetch`, `git pull`, or anything else that
  changes git state, and do not post comments, reviews, or approvals.

## Evaluation

Evaluate whether the changes are:

- Correct and complete.
- As simple as practical.
- Consistent with the PR's stated intent.
- Accompanied by appropriate tests and documentation updates.

The PR description may describe an implementation strategy rather than the
underlying problem. Infer the intended outcome and assess whether a better
solution would be appropriate.

Also report:

- Review comments that remain unaddressed by the current head.
- Failing CI checks, with your assessment of whether this PR causes them.

## Scope

- Report only issues introduced by the PR. Do not report preexisting issues
  unless the PR introduces or worsens them.
- Don't review or report on files that git ignores, or on
  `agent-council-reports/` (agent-council's output, which may not be
  ignored).
- You may suggest improvements to the PR title and description.

## Verification

Investigate thoroughly before reaching conclusions.

You are permitted and encouraged to inspect files, run Git commands, execute
relevant tests and linters, and reproduce suspected defects.

**DO NOT EDIT ANY CODE OR TRACKED FILES.**

Tests and linters that generate temporary files or coverage data are
permitted (builds are not); direct their output to your scratch
directory where the tool allows it. Avoid unnecessary modifications to the
working tree.

For each issue, identify the affected file and location, explain the problem
and its impact, and propose a fix. Say how you verified it (for example, a
reproduction or a test run), or that it is unverified.
