# frozen_string_literal: true

# AgentCouncil::Ps — what agent-council-ps shows: each running
# agent-council process, its agents (the children it spawned, each leading
# a process group of its own; see WorkerPool), and the commands each agent
# is running, read from ps. It runs outside agent-council, so it sees only
# what the operating system shows: an agent's event stream goes to
# agent-council through a pipe and isn't visible here.

require 'io/console'
require 'open3'
require_relative 'harnesses'
require_relative 'plain_line'

module AgentCouncil
  module Ps
    class Error < StandardError; end

    # A bad command line.
    class UsageError < Error; end

    # A process as ps lists it. elapsed and cpu are seconds. argv is its
    # exact argument list where /proc gives it (see proc_argv), else nil;
    # args is its command line as ps shows it, arguments joined by spaces.
    Entry = Struct.new(:pid, :ppid, :pgid, :elapsed, :cpu, :rss_kb, :args, :argv) do
      def tokens = argv || args.split
      def command_name = File.basename(tokens.first.to_s)
    end

    # pid, ppid, pgid, elapsed time, CPU time, RSS (KiB), command line. -ww
    # keeps macOS's ps from cutting the command line at the terminal's width.
    PS_ARGV = %w[ps -ww -A -o pid=,ppid=,pgid=,etime=,time=,rss=,args=].freeze

    # A line of PS_ARGV's output: pid, ppid, pgid, etime, time, rss, and
    # the command line (which may be empty).
    ENTRY_LINE = /\A\s*(\d+)\s+(\d+)\s+(\d+)\s+([\d:.-]+)\s+([\d:.-]+)\s+(\d+)(?:\s+(.*))?\z/

    # Ruby interpreters agent-council may run under, by command name: MRI
    # (possibly versioned, e.g. ruby3.4), or JRuby, whose launcher runs java.
    RUBY = /\A(ruby[\d.]*|jruby)\z/
    # JRuby's main class: org.jruby.main.Main from 10.1, org.jruby.Main
    # before.
    JRUBY_MAINS = %w[org.jruby.main.Main org.jruby.Main].freeze

    # RVM's executable-hooks wrapper, which runs installed gems' commands
    # under RVM: ruby_executable_hooks, or under JRuby,
    # jruby_executable_hooks.
    EXECUTABLE_HOOKS = /\A\w*_executable_hooks\z/

    # Ruby options whose argument can be the next word (MRI's, and the
    # ones JRuby shares with it), so that word isn't taken for the script.
    RUBY_OPTIONS_WITH_ARGUMENT = %w[
      -C -E -I -r --backtrace-limit --crash-report --disable --dump --enable --encoding
      --external-encoding --internal-encoding --parser
    ].freeze

    # Bundler's command, by name: bundle or bundler, possibly versioned
    # (e.g. bundle3.4), as RUBY allows ruby3.4.
    BUNDLE = /\Abundler?[\d.]*\z/
    # The word that runs a given version of a gem's command, as in
    # `bundle _4.0.19_ exec`.
    GEM_VERSION_SELECTOR = /\A_\S+_\z/

    # What the report says when it finds no run to show: none at all, or
    # none with the pids asked for.
    module_function def no_runs_line(pids)
      return 'No running agent-council found.' if pids.empty?

      "No running agent-council, or agent of one, has pid #{pids.join(' or ')}."
    end

    DEFAULT_WATCH_SECONDS = 5

    HELP = <<~HELP.freeze
      Usage: agent-council-ps [-w[SECONDS] | --watch[=SECONDS]] [PID ...]

      Shows each running agent-council process, its agents, and the commands
      each agent is running, so you can tell what an agent that's taking
      longer than expected is doing. Each agent's pid is the one agent-council
      printed as it started: under "Started Agents:", or for the consolidator,
      under its "Consolidation Report" heading.

      For each agent it shows its harness and, where the harness's command
      line shows it, its model (not for pi, which hides its command line);
      how long it has run; its CPU time and recent CPU use (an agent waiting
      on its model uses little); its memory; and the commands and helper
      processes (such as MCP servers) it started that are still running,
      with how long each has run.

      PID:  show only the agent-council runs with this pid, or with an agent
            with this pid (default: every run)

      Options:
        -w, --watch  refresh every #{DEFAULT_WATCH_SECONDS} seconds until Ctrl-C; -wSECONDS
                     or --watch=SECONDS to choose the interval (e.g. -w30). The
                     interval must be attached: in "-w 30", 30 is a PID.
        -h, --help   show this help

      The first list comes after a second, the time CPU use is sampled over.

      To stop one agent and let the run go on: kill -TERM -PID
      See RUNAWAY_AGENTS.md in the gem for more.
    HELP

    # Seconds in a ps etime or time value: [[DD-]HH:]MM:SS, with fractional
    # seconds on macOS (whose time may also run past 59 minutes).
    module_function def parse_duration(text)
      text = text.to_s
      days, clock = text.include?('-') ? text.split('-', 2) : [0, text]
      clock.split(':').map(&:to_f).reduce(0) { |sum, part| (sum * 60) + part } + (days.to_i * 86_400)
    end

    # Text from ps, lsof, or /proc as UTF-8, invalid bytes becoming U+FFFD,
    # whatever the locale, so a command line with other bytes can't make
    # parsing raise.
    module_function def utf8(text) = String.new(text, encoding: Encoding::UTF_8).scrub

    # The processes in ps output (see PS_ARGV), by pid. A line that isn't
    # one (see ENTRY_LINE) continues the last one's command line, in case a
    # ps prints a newline in one.
    module_function def parse_ps(output)
      entries = []
      utf8(output).each_line(chomp: true) do |line|
        unless (match = ENTRY_LINE.match(line))
          entries.last.args += " #{line.strip}" if entries.last
          next
        end

        pid, ppid, pgid, etime, time, rss, args = match.captures
        entries << Entry.new(pid.to_i, ppid.to_i, pgid.to_i, parse_duration(etime), parse_duration(time),
          rss.to_i, args.to_s)
      end
      entries.to_h { |entry| [entry.pid, entry] }
    end

    module_function def ps_snapshot
      output, status = Open3.capture2(*PS_ARGV)
      raise Error, "ps failed (#{status})" unless status.success?

      processes = parse_ps(output)
      processes.each_value do |process|
        process.cpu = proc_cpu(process.pid) || process.cpu
        process.argv = proc_argv(process.pid)
      end
    rescue SystemCallError => e
      raise Error, "can't run ps: #{e.message}"
    end

    # Linux's ps gives CPU time in whole seconds, too coarse for CPU use over
    # a few seconds; /proc gives it in clock ticks. nil where there's no
    # /proc, as on macOS, whose ps gives hundredths.
    module_function def proc_cpu(pid)
      ticks = parse_proc_stat(File.binread("/proc/#{pid}/stat"))
      ticks && (ticks.to_f / clock_ticks)
    rescue SystemCallError
      nil
    end

    # The CPU time (user plus system, in clock ticks) in the contents of a
    # /proc/PID/stat, or nil if it can't be read from them. Those are fields
    # 14 and 15; the command name (field 2) is in parentheses and may
    # contain spaces and parentheses, so fields are counted from its last ")".
    module_function def parse_proc_stat(stat)
      close = stat.rindex(')') or return nil
      utime, stime = stat[(close + 1)..].split[11, 2]
      return nil unless [utime, stime].all? { |field| field&.match?(/\A\d+\z/) }

      utime.to_i + stime.to_i
    end

    # A process's exact arguments, from /proc/PID/cmdline, or nil where
    # there's no /proc (as on macOS) or it's empty (as for a kernel
    # thread or a zombie). ps joins the arguments with spaces, so a path
    # containing one would otherwise be split.
    module_function def proc_argv(pid)
      argv = utf8(File.binread("/proc/#{pid}/cmdline")).split("\0")
      argv unless argv.empty?
    rescue SystemCallError
      nil
    end

    module_function def clock_ticks
      @clock_ticks ||= begin
        require 'etc'
        Etc.sysconf(Etc::SC_CLK_TCK) || 100
      rescue StandardError, NotImplementedError
        100
      end
    end

    # Whether process is agent-council: a Ruby interpreter running the
    # agent-council script (as its shebang or a binstub runs it), or under
    # JRuby, java running JRuby's main class with it; under either, it may
    # run it through `bundle exec`. Only the script is checked, a word whose
    # basename is exactly agent-council, so a process merely mentioning
    # agent-council, such as an agent whose system prompt names it, or
    # agent-council-ps itself, isn't taken for it.
    #
    # Under MRI, `bundle exec` loads the script into Bundler's own process
    # and retitles it with the script's path and arguments, so a process
    # whose command starts with the script's path is one too; see
    # bundler_title?. RVM's executable-hooks wrapper, which runs installed
    # gems' commands under RVM, retitles its process too, as "ruby",
    # the script's path, and its arguments; under JRuby, it's shown as
    # run (see ruby_script_index).
    #
    # A retitled process's exact arguments (from /proc, as on Linux) are
    # its title, one string, which is split at spaces. Where there's no
    # /proc, as on macOS, or it can't be read (argv is nil), the words are
    # ps's command line split at spaces. In either case, a script whose
    # path has a space in it isn't found; only a process's exact
    # arguments, not retitled, keep it whole. Without /proc, any command
    # starting with a path whose basename is agent-council is taken for a
    # run Bundler retitled. cwd: gives a process's working directory (see
    # bundler_title?).
    module_function def agent_council?(process, cwd: method(:process_cwd))
      return true if process.argv && bundler_title?(process, cwd)

      tokens = process.argv&.size == 1 ? process.argv.first.split : process.tokens
      command = File.basename(tokens.first.to_s)
      offset =
        if RUBY.match?(command)
          1
        elsif command == 'java' && (main = tokens.index { |token| JRUBY_MAINS.include?(token) })
          main + 1
        end
      return process.argv.nil? && script?(tokens.first) unless offset

      index = ruby_script_index(tokens.drop(offset))
      !index.nil? && script?(tokens[offset + index])
    end

    module_function def script?(word) = File.basename(word.to_s) == 'agent-council'

    # Whether a process's exact arguments (from /proc, as on Linux) are a
    # title Bundler gave it: one string, starting with the path of an
    # existing file named agent-council (relative to the process's working
    # directory, if not absolute, so not if that can't be read, as for
    # another user's process). It's split at spaces, so a script whose
    # path has a space in it isn't found. The file must exist, so that,
    # say, a script named `agent-council backup`, or a program at
    # `.../agent-council work/bin/tool`, isn't taken for one, unless a file
    # named agent-council is in the same directory as well (a limitation
    # RUNAWAY_AGENTS.md documents).
    module_function def bundler_title?(process, cwd)
      path = process.argv.first.to_s.split.first
      script?(path) && existing_file?(path, process, cwd)
    end

    # Whether path names an existing file, relative to the process's
    # working directory if not absolute. A path that can't be expanded,
    # such as one starting with "~" and an unknown user's name, doesn't.
    module_function def existing_file?(path, process, cwd)
      dir = cwd.call(process.pid) unless path.start_with?('/')
      return false unless path.start_with?('/') || dir

      File.file?(File.expand_path(path, dir || '/'))
    rescue ArgumentError
      false
    end

    # The index in a Ruby interpreter's arguments of its script: the first
    # word that isn't an option or an option's argument, or if that's
    # bundle running exec (as JRuby shows `bundle exec`, not retitling its
    # process), the script it runs (see bundle_exec_command_index); nil if
    # there's none, or if -e gives the code to run instead. RVM's wrapper
    # (see EXECUTABLE_HOOKS), which JRuby shows too, is passed over: the
    # script is the word after it, or the one bundle exec runs.
    module_function def ruby_script_index(args)
      index = 0
      while index < args.size
        arg = args[index]
        return (index + 1 if index + 1 < args.size) if arg == '--'
        return nil if arg.start_with?('-e')

        unless arg.start_with?('-')
          # RVM's wrapper runs the script it's given.
          index += 1 if EXECUTABLE_HOOKS.match?(File.basename(arg))
          return nil unless index < args.size
          return index unless (exec = bundle_exec_index(args, index))

          return bundle_exec_command_index(args, exec + 1)
        end
        index += RUBY_OPTIONS_WITH_ARGUMENT.include?(arg) ? 2 : 1
      end
      nil
    end

    # If args[index] is Bundler's command (see BUNDLE) running exec,
    # possibly with a version first (see GEM_VERSION_SELECTOR), the index
    # of exec; else nil.
    module_function def bundle_exec_index(args, index)
      return unless BUNDLE.match?(File.basename(args[index]))

      index += 1 if GEM_VERSION_SELECTOR.match?(args[index + 1].to_s)
      index + 1 if args[index + 1] == 'exec'
    end

    # The index in args of the command `bundle exec` runs, the first word
    # from index on that isn't one of exec's options (such as
    # --keep-file-descriptors) or --gemfile's argument; nil if none.
    module_function def bundle_exec_command_index(args, index)
      while index < args.size
        return index unless args[index].start_with?('-')

        index += args[index] == '--gemfile' ? 2 : 1
      end
      nil
    end

    module_function def children(processes, pid)
      processes.each_value.select { |process| process.ppid == pid }
    end

    # Every process descended from pid, depth first, with its depth (1 for a
    # child).
    module_function def descendants(processes, pid, depth = 1)
      children(processes, pid).sort_by(&:pid).flat_map do |child|
        [[child, depth], *descendants(processes, child.pid, depth + 1)]
      end
    end

    # The harness an agent's command line runs (its NAME), or nil. A node
    # harness's can show as "node /path/to/pi ...", so it's the first word
    # naming one.
    module_function def harness_name(process)
      process.tokens.each do |token|
        break if token.start_with?('-')

        name = File.basename(token)
        return name if Harnesses::BY_NAME.key?(name)
      end
      nil
    end

    # "provider / model" from an agent's command line, as far as it shows
    # them, read by its harness (see Harnesses::Harness.model_label), or,
    # for a command line that names none (as a harness run some other way
    # might not), by Harness's default. pi replaces its command line with
    # "pi", so a pi agent's gives neither (and this returns "").
    module_function def model_label(process)
      harness = Harnesses::BY_NAME[harness_name(process)] || Harnesses::Harness
      harness.model_label(process.tokens)
    end

    # The agent-council processes to show and their agents: [[council,
    # [agent, ...]], ...]. An agent is a child leading its own process group.
    # pids: only the runs that have one of these pids, or an agent with one
    # (all if empty). cwd: as for agent_council?; it's called at most once
    # per process.
    module_function def runs(processes, pids: [], cwd: method(:process_cwd))
      cwd = memoized(cwd)
      result = processes.each_value.select do |process|
        agent_council?(process, cwd: cwd)
      end.sort_by(&:pid).map do |council|
        [council, children(processes, council.pid).select { |child| child.pgid == child.pid }.sort_by(&:pid)]
      end
      return result if pids.empty?

      result.select { |council, agents| [council, *agents].map(&:pid).intersect?(pids) }
    end

    # A callable's results, by argument; see memoized.
    Memo = Struct.new(:callable, :results) do
      def call(arg) = results.fetch(arg) { results[arg] = callable.call(arg) }
    end

    # callable, called at most once per argument; callable itself if it's
    # already memoized, so that passing one on doesn't wrap it again.
    module_function def memoized(callable)
      callable.is_a?(Memo) ? callable : Memo.new(callable, {})
    end

    # HH:MM:SS, rounded to the second, as agent-council prints durations
    # (hours may exceed 23).
    module_function def format_duration(seconds)
      seconds = seconds.round
      format('%02d:%02d:%02d', seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    end

    module_function def format_rss(kib)
      kib >= 1024 * 1024 ? format('%.1f GB', kib / 1024.0 / 1024) : "#{kib / 1024} MB"
    end

    # CPU use since previous (an earlier snapshot), as a percentage of one
    # core, or nil if the process wasn't in it (or was another process with
    # the same pid).
    module_function def cpu_percent(process, previous, interval)
      before = previous&.[](process.pid)
      return nil if before.nil? || interval <= 0 || before.elapsed > process.elapsed

      ((process.cpu - before.cpu) / interval * 100).clamp(0, Float::INFINITY).round
    end

    # The report's lines for one snapshot. previous and interval (seconds
    # between them) give recent CPU use; width cuts command lines.
    # selected: the runs to show, by default those runs finds.
    module_function def report(processes, pids: [], previous: nil, interval: 0, width: 100,
      cwd: method(:process_cwd), selected: nil)
      cwd = memoized(cwd)
      selected ||= runs(processes, pids: pids, cwd: cwd)
      return [no_runs_line(pids)] if selected.empty?

      selected.flat_map do |council, agents|
        run_lines(processes, council, agents, previous, interval, width, cwd.call(council.pid))
      end
    end

    module_function def run_lines(processes, council, agents, previous, interval, width, dir)
      heading = "agent-council pid #{council.pid}, running #{format_duration(council.elapsed)}"
      heading += ", in #{AgentCouncil.plain_line(dir)}" if dir
      lines = [heading]
      lines << '  (no agents running)' if agents.empty?
      agents.each do |agent|
        lines << agent_line(agent, previous, interval)
        lines.concat(command_lines(processes, agent, width))
      end
      lines << ''
    end

    module_function def agent_line(agent, previous, interval)
      parts = [harness_name(agent) || agent.command_name, model_label(agent)]
      name = parts.map { |part| AgentCouncil.plain_line(part) }.reject(&:empty?).join('  ')
      cpu = "cpu #{format_duration(agent.cpu)}"
      percent = cpu_percent(agent, previous, interval)
      cpu += " (#{percent}% now)" if percent
      "  - pid #{agent.pid}  #{name}  running #{format_duration(agent.elapsed)}  #{cpu}  " \
        "#{format_rss(agent.rss_kb)}"
    end

    # The commands the agent started that are still running, by the
    # process tree (its own commands may be in other process groups).
    module_function def command_lines(processes, agent, width)
      descendants(processes, agent.pid).map do |process, depth|
        prefix = "#{'    ' * depth}  #{process.pid}  #{format_duration(process.elapsed)}  "
        command = AgentCouncil.plain_line(process.args)
        room = [width - prefix.size, 20].max
        command = "#{command[0, room - 1]}…" if command.size > room
        "#{prefix}#{command}"
      end
    end

    # A process's working directory, where agent-council puts its reports
    # by default, or nil if it can't be read.
    module_function def process_cwd(pid)
      link = "/proc/#{pid}/cwd"
      return utf8(File.readlink(link)) if File.symlink?(link)

      output, status = Open3.capture2('lsof', '-a', '-p', pid.to_s, '-d', 'cwd', '-Fn', err: File::NULL)
      utf8(output)[/^n(.+)$/, 1] if status.success?
    rescue SystemCallError
      nil
    end

    # Parses the command line: [watch_seconds or nil, pids], or raises
    # UsageError. A watch interval must be attached (-w30, --watch=30),
    # so that in "-w 48212" the number is a pid.
    module_function def parse_args(argv)
      watch = nil
      pids = []
      argv.each do |arg|
        case arg
        when '-w', '--watch' then watch = DEFAULT_WATCH_SECONDS
        when /\A(?:-w|--watch=)(.*)\z/m then watch = parse_interval(::Regexp.last_match(1))
        when /\A\d+\z/ then pids << arg.to_i
        else raise UsageError, "unknown argument: #{arg}"
        end
      end
      [watch, pids]
    end

    module_function def parse_interval(text)
      seconds = Float(text, exception: false) if text.match?(/\A(\d+(\.\d*)?|\.\d+)\z/)
      raise UsageError, "the watch interval must be a number of seconds, not #{text.inspect}" unless seconds
      raise UsageError, 'the watch interval must be more than 0' unless seconds.positive?

      seconds
    end

    module_function def terminal_width(out)
      columns = out.winsize[1] if out.tty? && out.respond_to?(:winsize)
      columns&.positive? ? columns : 100
    rescue SystemCallError
      100
    end

    # Prints one snapshot, with CPU use over a second, and returns the exit
    # status: 0, or 1 if no run was found (or none with the pids asked
    # for). Watching, it prints the first after that second too, then one
    # every watch seconds, with CPU use since the last, until interrupted
    # (Interrupt is raised to the caller). snapshot, pause, and cwd are
    # seams for the specs.
    module_function def run(argv, out: $stdout, snapshot: method(:ps_snapshot), pause: method(:sleep),
      cwd: method(:process_cwd))
      watch, pids = parse_args(argv)
      previous = snapshot.call
      previous_at = monotonic_now
      pause.call(1)
      loop do
        processes = snapshot.call
        now = monotonic_now
        snapshot_cwd = memoized(cwd)
        selected = runs(processes, pids: pids, cwd: snapshot_cwd)
        lines = report(processes, pids: pids, previous: previous, interval: now - previous_at,
          width: terminal_width(out), cwd: snapshot_cwd, selected: selected)
        if watch
          out.print("\e[H\e[2J") if out.tty?
          out.puts("#{Time.now.strftime('%H:%M:%S')}, every #{format('%g', watch)}s; Ctrl-C to stop")
        end
        out.puts(lines)
        out.flush
        return selected.empty? ? 1 : 0 unless watch

        previous = processes
        previous_at = now
        pause.call(watch)
      end
    end

    module_function def monotonic_now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
