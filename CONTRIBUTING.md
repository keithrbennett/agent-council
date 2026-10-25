# Contributing to agent-council

[Back to the main README](README.md)

Thank you for your interest in contributing.

Bug reports, feature proposals, documentation suggestions, and other feedback are welcome.

---

## Before Submitting a Pull Request

Please do not submit a pull request unless you have first opened an issue and received explicit approval from the maintainer to proceed.

Discussing a proposal in an issue does not by itself constitute approval. Please wait until the maintainer specifically confirms that a pull request would be welcome.

This project is maintained by a single developer. Even a well-intentioned and technically sound pull request can require substantial review, testing, discussion, and ongoing maintenance. A proposed change may also conflict with the project's scope, design, priorities, or planned work. agent-council is deliberately small: see the design rule and the status and future work section in [DESIGN.md](DESIGN.md).

The contribution process is:

1. Open an issue describing the problem or proposed improvement.
2. Discuss the desired behavior and, when useful, the likely implementation.
3. Wait for explicit approval to prepare a pull request.
4. Submit a pull request only after receiving that approval.

Pull requests submitted without prior approval may be closed without detailed review.

### AI-Assisted Contributions

AI-assisted work is welcomed. The same prior-approval requirement applies whether the work is produced manually or with AI assistance.

Contributors are responsible for supervising and validating their work. A pull request should not shift the primary burden of reviewing, debugging, or establishing correctness to the maintainer.

---

## Reporting Issues

Before opening an issue:

- Check whether an existing issue already addresses the subject.
- Include clear reproduction steps when reporting a problem.
- Describe the expected and actual behavior.
- Include your agent-council version (`agent-council -v`), pi version (`pi --version`), Ruby version (`ruby -v`), and operating system (and whether you are running under WSL).
- Name the providers and models involved, if the problem concerns particular ones.
- Include relevant agent-council output, while removing API keys and other sensitive information.

Reports and agent output can quote the analyzed project's code and anything the agents read or ran. Review them before posting, especially for a private project.

---

## Preparing an Approved Change

After receiving explicit approval to submit a pull request:

1. Fork the repository on GitHub.
2. Clone your fork and enter the project directory:

   ```bash
   git clone https://github.com/YOUR-USERNAME/agent-council.git
   cd agent-council
   ```

3. Create a branch for your work:

   ```bash
   git checkout -b feature/my-change
   ```

4. With Ruby 3.3 or later (or JRuby 10 or later), install dependencies, and optionally the pre-commit hook that runs the tests and RuboCop:

   ```bash
   bin/setup
   bin/setup-hooks
   ```

5. Make your changes, following the project's existing coding style.
6. Test and validate the changes as described below.
7. Commit the changes with a clear, informative message.
8. Push the branch and open a pull request against `main`.

Pull requests should:

- Link to the issue in which the change was approved.
- Include or update tests for new or changed behavior.
- Pass the tests and RuboCop checks.
- Update documentation and examples when behavior changes.
- Explain how the change was tested and validated.
- Clearly distinguish testing with stubs from testing with real pi runs.

---

## Testing Approved Changes

Run the tests and RuboCop before submitting a pull request:

```bash
bundle exec rspec
bundle exec rubocop
```

The tests make no model calls. For changes affecting how pi is invoked or how its output is handled, also run agent-council for real, for example with the smoke-test prompt:

```bash
./exe/agent-council examples/prompts/smoke-test_prompt.md examples/configs/single.yml
```

`single.yml` names one provider and model; if you lack credentials for them, copy it and substitute a pair from `pi --list-models`, so a missing credential isn't mistaken for a bug in your change. Real runs send whatever the agents read and run to the configured providers, and cost money; see "Safety and privacy" in the [README](README.md#safety-and-privacy).

In the pull request, identify:

- The pi version and Ruby implementations and versions tested (CI covers several Ruby and JRuby versions).
- Whether testing included real pi runs, and with which providers.
- Any relevant behavior that could not be tested.

---

## Maintenance

### Security audit

`bundle exec rake security` runs bundler-audit (the bundle's gems) and ruby-audit (the Ruby and RubyGems versions). CI runs it on pushes and pull requests to `main`, on demand, and weekly to catch new advisories. GitHub disables scheduled workflows in public repositories after 60 days without activity; re-enable the Security workflow from the Actions tab.

agent-council has no runtime gem dependencies, so bundler-audit findings concern the development environment, not what users install; ruby-audit findings concern the Ruby and RubyGems versions it runs on.

- **A vulnerable gem:** run `bundle update <gem>`, then rerun the audit and the tests. If a Gemfile constraint blocks the fixed version, raise the constraint (CI resolves fresh, since `Gemfile.lock` isn't committed).
- **A ruby-audit finding:** upgrade Ruby, or RubyGems with `gem update --system`.

### Dependencies

The RuboCop versions are pinned in the Gemfile and bumped deliberately.
