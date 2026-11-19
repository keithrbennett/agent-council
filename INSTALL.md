# Installing agent-council from scratch

This guide is for developers comfortable with the command line who have
never used Ruby. It takes you from a bare machine to a working
`agent-council` command. Already have Ruby 3.3+ (or JRuby 10+) and
a harness CLI (`pi`, Claude Code, or Codex)? Just run `gem install agent-council`; see the
[README](README.md#quick-start).

## 1. Prepare your system

- **macOS and Linux:** any terminal works. Linux needs `curl` installed.
- **Windows:** native Windows is **not supported**. Everything, including
  Ruby, the harness CLIs you use (Pi, Claude Code, Codex, or any mix), and
  agent-council, must be installed and run inside
  [WSL](https://learn.microsoft.com/windows/wsl/install) with Ubuntu. In
  an administrator PowerShell, run `wsl --install -d Ubuntu`, restart if
  asked, then open an Ubuntu terminal and follow the Linux steps below
  in it. Keep your projects in the Linux filesystem (e.g. `~/projects`),
  not under `/mnt/c`.

On Ubuntu/WSL, install the basics first:

```bash
sudo apt update && sudo apt install -y curl build-essential
```

## 2. Install Ruby with Mise

[Mise](https://mise.jdx.dev) is a version manager for languages. It is
used here because it provides current Ruby versions, installs them in
your home directory without touching any system Ruby, and works the same
way on macOS, Linux, and WSL.

Install Mise and activate it in your shell.

Zsh:

```zsh
curl -fsSL https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> "${ZDOTDIR:-$HOME}/.zshrc"
```

Bash:

```bash
curl -fsSL https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate bash)"' >> ~/.bashrc
```

On macOS, Bash reads `~/.bashrc` only if `~/.bash_profile` sources it. If
yours doesn't, add `[ -f ~/.bashrc ] && . ~/.bashrc` to `~/.bash_profile`.

Open a new terminal window (or tab) so the activation takes effect, then
install Ruby 4.0 and make it your default:

```bash
mise use --global ruby@4.0
```

Mise downloads a precompiled Ruby where one exists, and otherwise compiles
it, which needs a C toolchain and some libraries. If the install fails
for that reason, install the
[ruby-build suggested build environment](https://github.com/rbenv/ruby-build/wiki#suggested-build-environment)
for your system (on macOS, the Xcode command line tools: `xcode-select --install`)
and run the command again.

Verify:

```bash
ruby -v    # should print ruby 4.0.x
```

For other install methods and details, see the
[Mise documentation](https://mise.jdx.dev/getting-started.html) and its
[Ruby page](https://mise.jdx.dev/lang/ruby.html).

## 3. Install a harness: Pi, Claude Code, Codex, or several

agent-council drives AI models through a coding-agent harness, which
each config entry names. Most samples use the
[Pi](https://github.com/earendil-works/pi) coding agent, version 1.0.4
or later. To use it, install Pi by
following its [installation instructions](https://github.com/earendil-works/pi),
and configure it with credentials for **at least one AI model provider**
(see [Pi's documentation](https://pi.dev/docs/latest)). Under WSL, do both
inside WSL.

Agents can also run under [Claude Code](https://code.claude.com/docs)
(see the README's [Choosing a harness](README.md#choosing-a-harness)).
For those, install the `claude` CLI and log in (under WSL, inside WSL).
Likewise for [Codex](https://developers.openai.com/codex/cli): install
the `codex` CLI and log in. A config needs each harness only if some
agent, or the consolidator, runs under it (`harness: pi`, `claude`, or
`codex`).

## 4. Install agent-council

```bash
gem install agent-council
agent-council -h
```

If the help text appears, you're done.

## Next steps

Continue with the README's [Quick start](README.md#quick-start) to list
your models, write a config, and do your first run. You've already done its
steps for installing the prerequisites and the gem.
