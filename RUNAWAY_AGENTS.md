# Runaway agents and time limits

agent-council has no time limit of its own: a run lasts until every
agent finishes. This document explains why, what can go wrong without
one, how to stop a runaway agent yourself, and how to put a limit on a
run with the `timeout` command.

## The problem

Now and then an agent doesn't finish. Its siblings finish in minutes,
and it goes on for an hour or more, holding up the run (the
consolidator starts only after every review agent has finished) and,
on pay-per-token providers, running up cost. Its tokens and cost
aren't in the run's totals if you stop the run, since an interrupted
agent records no usage (see [How far to trust the
cost](README.md#how-far-to-trust-the-cost)).

The cause may be the particular model or provider: if one entry in
your config keeps doing it, try removing it.

## Why there is no built-in limit (yet)

A limit is easy to write; a good default is not:

- **Legitimate runs vary enormously.** How long an agent takes depends
  on the prompt, the size of the repository, the model, the provider's
  speed and load, and the harness. A whole-codebase review can
  legitimately take hours; a smoke test takes seconds. A default
  short enough to catch a runaway early would kill real work, and one
  long enough never to do that would rarely help.
- **A false positive can cost more than the runaway.** Stopping an
  agent that was doing real work throws away everything it did: an
  agent stopped before writing its report leaves nothing behind, however
  far along it was. The tokens and money it spent are gone, and so is
  the time, often an hour or more, and getting that report means
  running it again from the start. A limit that stops the whole run
  does this to every agent still working.
- **Silence is not the symptom.** A limit that stops an agent only
  after it has produced no output for a while would not have caught
  the runaways seen so far, since they never stopped producing output.
- **Token or cost caps could behave differently by harness.** Stopping
  an agent at a token or cost budget would catch a runaway whatever its
  timing, but it depends on what each harness reports while it runs:
  how often, how accurately, and what it counts. If that differs, the
  same cap would mean different things for different agents in one
  config, which would be confusing at best and misleading at worst.
  Even if the harnesses agreed today, supporting another harness later
  could bring in the difference.
- **Sleep shouldn't count, but may.** Nothing runs while the computer
  sleeps, so time asleep shouldn't count toward a limit; counting it
  can stop an agent that was making progress as soon as the computer
  wakes. Whether it counts depends on the clock the timer uses, which
  differs by operating system and, for the `timeout` command, by
  implementation (see below).

## Seeing what an agent is doing

Before stopping an agent that is taking longer than expected, you can
check what it is doing with `agent-council-ps`, which the gem
installs next to `agent-council`. Run it in another terminal:

```
$ agent-council-ps
agent-council pid 48200, running 01:02:13, in /home/me/project
  - pid 48211  pi  running 01:02:10  cpu 00:03:12 (2% now)  210 MB
  - pid 48212  pi  running 01:02:10  cpu 00:01:40 (0% now)  190 MB
      48390  00:41:07  /bin/bash -c npm test
          48391  00:41:07  node node_modules/.bin/jest
```

For each running agent-council, it shows the agent-council process's
ID, how long it has been running, and its working directory. Under that
it lists the agents the process is running, each by the process ID
agent-council printed when the agent started (under `Started Agents:`,
or for the consolidator, under its `Consolidation Report` heading).
For each agent it shows:

- its harness and, where the harness's command line shows it, its
  model. pi replaces its command line with plain `pi`, so a pi agent's
  line shows no model; match its process ID to the `Started Agents:`
  line to see which agent it is.
- how long it has been running, its CPU time, its CPU use over the
  last second (in watch mode, since the last refresh), and its memory.
- the processes it started that are still running, such as the
  commands it runs and any MCP servers its harness started, with how
  long each has been running.

Above, agent #2 has been waiting 41 minutes for a test run to finish.

- `-w` or `--watch` refreshes the list every 5 seconds until Ctrl-C.
  To choose the interval, attach it: `-w30` or `--watch=30`.
- Process IDs limit the list to the runs that have those IDs, or that
  have agents with those IDs: `agent-council-ps 48212`.
- Several runs, including runs in the same directory, are listed
  separately, each with its own agents. agent-council-ps doesn't show each
  run's run dir, which can't be told reliably from outside the
  process. The `Run Dir:` line that the run printed when it started
  gives it.

What it can't show: it reads only what the operating system shows
(through `ps`, and `lsof` on macOS), so it can't see an agent's
conversation with its model, which goes only to agent-council. Low CPU
use is normal for an agent waiting on its model. An agent that has no
long-running command, and whose sibling agents finished long ago, may
be stuck in a loop with its model, and only stopping it will end that.

## Stopping one agent

Each agent's process ID is printed under `Started Agents:` as it
starts (and `agent-council-ps` lists the running ones; see [Seeing what
an agent is doing](#seeing-what-an-agent-is-doing)):

```
Started Agents:
  - pid 48211  #1 deepseek / deepseek-flash
  - pid 48212  #2 deepseek / deepseek-flash
```

Each agent leads a process group with that ID, so this stops agent #2,
and the commands it started that are in its group, while the others go
on:

```bash
kill -TERM -48212
```

The stopped agent is listed under `Finished Agents:` as failed, with a
reason such as `pi was stopped by SIGTERM`, and the run goes on as
usual: it's recorded as failed in `run.json`, and the consolidator
still runs on the other agents' reports. Its usage is what its output
had reported by then, which may be little or nothing.

- **The commands it started.** pi, Claude Code, and Codex stop them on
  SIGTERM. OpenCode doesn't, and may not exit at all (it didn't within
  5 seconds in a check with 1.19.6); `kill -KILL -48212` then stops it,
  but not its commands, which run in process groups of their own and
  are left running.
- **Its output.** agent-council waits for the agent's output to close,
  so a process the agent started that kept it open keeps the run
  waiting until that process exits too.
- **The consolidator.** Its process ID is printed under the
  `Consolidation Report` heading as it starts, and it can be stopped the
  same way. That fails the consolidation, which is recorded in
  `run.json`. In a run that also ran the analysts, the exit status
  doesn't change, since only the analysts decide it; under
  `--consolidate`, where the consolidation is the run, it becomes 1.
  `agent-council --consolidate RUN_DIR` runs it again (see
  [Consolidating a finished run](README.md#consolidating-a-finished-run)).

## Limiting a run with `timeout`

agent-council has no built-in protection against runaway agents, but
the `timeout` command can serve as a very crude substitute: it can't
tell which agent is the problem, so it limits the whole run. [A shell
function](#a-shell-function) below makes it simpler to use.

The `timeout` command runs a command and sends it SIGTERM when a time
limit runs out. agent-council treats SIGTERM like Ctrl-C (see [Stopping
a run](README.md#stopping-a-run)): running agents get SIGTERM and a
shared 5 seconds to exit, and the reports already written are kept.

```bash
timeout --foreground 2h agent-council prompt.md
```

Durations take a suffix: `s` (the default), `m`, `h`, or `d`. When
the limit runs out, `timeout` exits with status 124, so a script can
tell a timeout from an agent-council failure.

If at least two analysts had written their reports, you can then
consolidate what was written (with only one, there's nothing to
compare it with, so it's usually better to read that report itself), as for any interrupted run (see
[Consolidating a finished run](README.md#consolidating-a-finished-run)):

```bash
agent-council --consolidate agent-council-reports/<date>/<time>
```

The agents that didn't finish count as having no report, with a note
that the reason wasn't recorded: a run stopped before every analyst
finished writes no `run.json`.

### Use `--foreground` in a terminal

Without `--foreground`, `timeout` moves itself and agent-council into
a new process group, out of the terminal's foreground, so Ctrl-C
doesn't reach agent-council: the run keeps going until the limit runs
out. (Checked with GNU coreutils 9.7 and uutils coreutils 0.10.0.)
With `--foreground`, Ctrl-C works as usual. `--foreground` also means
the limit's SIGTERM goes to agent-council alone, which is all that's
needed: each agent runs in a process group of its own, and
agent-council stops the agents itself.

In a script or cron job with no terminal, `--foreground` makes no
difference either way.

### Don't use `--kill-after` (`-k`) with a short delay

`-k DURATION` sends SIGKILL if the command is still running that long
after the SIGTERM. SIGKILL can't be handled, so a killed agent-council
can't stop its agents, which go on running (and billing) on their own.
agent-council normally exits within a few seconds of SIGTERM; if you
use `-k`, give it well over that, such as `-k 1m`.

### A shell function

To make this a habit, put a function like this in your `~/.bashrc` or
`~/.zshrc` (it works in bash and zsh, not in a plain POSIX `sh`). It
takes the limit first, then agent-council's usual arguments, uses
`gtimeout` where there's no `timeout`, and says how to recover when
the limit runs out:

```bash
agent-council-timeboxed() {
  if [ "$#" -lt 2 ]; then
    echo "usage: agent-council-timeboxed DURATION PROMPT_FILE [CONFIG_FILE] [OPTIONS]" >&2
    return 2
  fi
  local limit="$1"
  shift
  local timeout_cmd
  timeout_cmd=$(command -v timeout || command -v gtimeout) || {
    echo "agent-council-timeboxed: no timeout or gtimeout command found" >&2
    return 127
  }
  "$timeout_cmd" --foreground "$limit" agent-council "$@"
  local rc=$?
  if [ "$rc" -eq 124 ]; then
    echo "agent-council-timeboxed: stopped after $limit;" \
      "to consolidate what was written, run agent-council --consolidate RUN_DIR" >&2
  fi
  return "$rc"
}
```

```bash
agent-council-timeboxed 2h prompt.md my-config.yml
```

The run directory to consolidate is the `Run Dir:` that agent-council
printed when it started.

### What the limit covers

- **The whole run, not each agent.** If the limit runs out while
  reviews are running, every review agent still running is stopped:
  the limit can't tell a runaway from an agent that is just slow. If
  it runs out during
  consolidation, which starts only after every review agent has
  finished, the consolidator is stopped. Each stopped agent loses all
  its work, and you pay for it again when you rerun. Set the limit
  generously, with the slowest legitimate agent and the consolidation
  in mind: a limit that runs out too soon can waste far more than the
  runaway it's meant to stop.
- **Sleep, depending on the implementation.** The two `timeout`s
  differ:
  - **uutils coreutils** (the default `timeout` on recent Ubuntu
    releases) times the limit with `CLOCK_MONOTONIC`, which on Linux
    stops while the computer is suspended, so time asleep doesn't
    count toward the limit.
  - **GNU coreutils** (the default on most other Linux distributions,
    and `gtimeout` from Homebrew's `coreutils` on macOS) times it with
    `CLOCK_REALTIME`, which keeps going during suspend, so time asleep
    should count, and a run can be stopped as soon as the computer
    wakes. This hasn't been tested across an actual suspend.

  `timeout --version` says which one you have. (The clocks were read
  from `strace` output on Linux, not from documentation.)
- **macOS** has no `timeout`; install Homebrew's `coreutils` and use
  `gtimeout`.
