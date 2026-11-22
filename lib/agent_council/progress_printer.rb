# frozen_string_literal: true

# AgentCouncil::ProgressPrinter — prints a run's Started Agents and
# Finished Agents sections as WorkerPool#collect reports its analysts'
# spawns and finishes.

module AgentCouncil
  class ProgressPrinter
    # The line printed as an agent starts, giving its pid, which is also its
    # process group's id (see WorkerPool), so a running agent can be found
    # or stopped (e.g. kill -TERM -PID).
    def self.spawned_line(label, pid) = "  - pid #{pid}  #{label}"

    # Prints lines while agents run, flushed so they show at once when out
    # is a file or a pipe. (main's $stdout, a SafeStdout, doesn't raise if
    # it can't be written.)
    def self.puts_live(lines, out: $stdout)
      out.puts(lines)
      out.flush
    end

    # agent_count: how many agents will report. Their labels must be
    # unique, as analysts' are, carrying their agent numbers.
    def initialize(agent_count, out: $stdout)
      @agent_count = agent_count
      @out = out
      @accounted = {} # labels of the agents that have started or finished
      @held = [] # finish lines not yet printed
      @heading = "\nFinished Agents:"
    end

    def started(label, pid)
      self.class.puts_live([self.class.spawned_line(label, pid)], out: @out)
      @accounted[label] = true
      print_held
    end

    # lines: the agent's finish line and any under it. They wait until
    # every agent has started (or finished without starting, failing to
    # spawn), so that none prints among the Started Agents lines.
    def finished(label, lines)
      @held.concat(lines)
      @accounted[label] = true
      print_held
    end

    # Prints whatever is held, as when collecting ended before every agent
    # reported.
    def flush_held = print_held(force: true)

    private def print_held(force: false)
      return if @held.empty? || (!force && @accounted.size < @agent_count)

      self.class.puts_live([*@heading, *@held], out: @out)
      @heading = nil
      @held.clear
    end
  end
end
