# Review Latest Commit

Review the latest commit and any uncommitted changes.
Report only issues needing addressing.

Evaluate whether the changes are:

- Correct and complete.
- As simple as practical.
- Consistent with the commit's intent.
- Accompanied by appropriate tests and documentation updates.

The commit message may describe an implementation strategy rather than the
underlying problem. Infer the intended outcome and assess whether a better
solution would be appropriate.

## Scope

- Report only issues introduced by the latest commit or uncommitted changes.
- Report issues in uncommitted changes separately from those in the commit.
- Ignore files in `untracked/` and `agent-council-reports/`.
- Do not report preexisting issues unless the changes introduce or worsen them.
- You may suggest improvements to the commit message, particularly if the
  commit has not been pushed.

## Verification

Investigate thoroughly before reaching conclusions.

You are permitted and encouraged to inspect files, run Git commands, execute
relevant tests and linters, and reproduce suspected defects.

**DO NOT EDIT ANY CODE OR TRACKED FILES.**

Tests and verification tools that generate temporary files, coverage data,
or build artifacts are permitted. Avoid unnecessary modifications to the
working tree.

For each issue, identify the affected file and location, explain the problem
and its impact, and propose a fix. Say how you verified it (for example, a
reproduction or a test run), or that it is unverified.
