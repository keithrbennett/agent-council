# Review Documentation

Review the documentation of the repository in the current working directory.
Report only issues needing addressing.

Documentation includes the README, any other Markdown files, help and usage
output, code comments that describe behavior, and sample files such as
example configs and prompts.

Evaluate whether the documentation is:

- **Accurate:** it matches what the code actually does. Check commands,
  flags, option names, file names, paths, defaults, config keys, output
  formats, and version or prerequisite claims against the code.
- **Complete:** every user-facing feature, option, and behavior is
  documented, and nothing documented has been removed or renamed.
- **Consistent:** the documents agree with each other and with the help
  output, and use the same terms for the same things.
- **Usable by a newcomer:** someone starting from scratch can install,
  configure, and complete a first run by following it, without needing
  knowledge it doesn't provide. Steps are in a sensible order and the
  examples work as written.
- **Clear and concise:** free of ambiguity, redundancy, stale history, and
  text that is hard to find or easy to misread.

## Scope

- Report documentation problems only. Do not review the code except to
  verify what the documentation says about it.
- Ignore files in `untracked/` and `agent-council-reports/`.
- Treat the code as the source of truth when it disagrees with the
  documentation, unless the code's behavior looks like the bug; say so in
  that case.
- Skip purely stylistic preferences.

## Verification

Investigate thoroughly before reaching conclusions.

You are permitted and encouraged to inspect files, run the program's help
output, follow the documented steps and examples, and execute commands to
confirm or refute what the documentation claims. Don't rely on a claim being
plausible: check it.

**DO NOT EDIT ANY CODE OR TRACKED FILES.**

Commands that generate temporary files or other artifacts are permitted.
Avoid unnecessary modifications to the working tree.

For each issue, identify the document and location, quote the problematic
text, explain the problem and its impact on a reader, and propose replacement
wording or a fix. Say how you verified it (for example, a command you ran or
the code you compared against), or that it is unverified.

Order issues by importance: first those that would mislead or block a
reader, then omissions, then minor clarity problems.
