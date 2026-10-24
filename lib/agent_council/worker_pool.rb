# frozen_string_literal: true

require 'open3'

module AgentCouncil
  # Worker threads and agent processes for a run, and what Ctrl-C (or
  # SIGTERM, SIGHUP or SIGQUIT) does to them. main's rescue Interrupt calls
  # into this class for everything but its own message.
  #
  # Each agent process runs in its own process group (see #capture3), so a
  # terminal's Ctrl-C reaches only agent-council, never the agents. Once
  # #trap_signals is installed, the first INT, TERM, HUP or QUIT (not on
  # JRuby; see TERMINATING_SIGNALS) raises Interrupt in the main thread,
  # whose rescue calls #shutdown: it sends every agent SIGTERM (pi then also
  # stops any commands its bash tool started, which run detached and so would
  # survive the agent), waits up to the grace period for the workers to
  # finish, and SIGKILLs agents still running. A second trapped signal other
  # than HUP SIGKILLs them at once. Any HUP after the first signal is
  # ignored: a closing terminal can deliver two at once (one forwarded by the
  # shell, one from the kernel), which must not skip the graceful stop. A
  # signal agent-council was started ignoring (e.g. HUP under nohup) stays
  # ignored. Either way, agent-council then dies by the signal (see
  # .exit_by_signal).
  #
  # Agents run in worker threads, never the main thread, so the main thread
  # is always free to take the Interrupt. Workers report completion through
  # a queue and only the main thread prints, so nothing more is printed once
  # the Interrupt has been taken.
  class WorkerPool
    # Not QUIT on JRuby: the JVM reserves it for thread dumps, so trapping
    # it only prints a warning.
    TERMINATING_SIGNALS = (RUBY_ENGINE == 'jruby' ? %w[INT TERM HUP] : %w[INT TERM HUP QUIT]).freeze

    # Each agent leads a new process group, so terminal signals skip it and
    # #signal_child reaches the processes in that group (not ones a tool
    # detached into a group of their own).
    SPAWN_OPTIONS = { pgroup: true }.freeze

    # Ends the process as the signal would have, so the caller (e.g. a shell
    # running agent-council in a loop) sees it was killed by the signal, not
    # that it handled it. QUIT exits 131 instead, rather than dumping core.
    def self.exit_by_signal(name)
      unless name == 'QUIT'
        trap(name, 'SYSTEM_DEFAULT')
        Process.kill(name, Process.pid)
        sleep 1 # in case delivery isn't immediate
      end
      exit!(128 + Signal.list.fetch(name))
    end

    def initialize(grace:)
      @grace = grace
      @threads = []
      @finished = Queue.new # indexes of threads as they finish
      @uncollected = 0 # threads not yet #collect'ed
      @children = {} # agent pids (each also its process group id)
      @children_lock = Mutex.new
      @stop_signal = nil # set once shutdown starts signalling agents
      @first_signal = nil # the signal that started the shutdown
      # Taken by the first signal. A Queue, because JRuby can run two traps
      # at once (so checking @first_signal could let both through), and
      # MRI forbids Mutex#lock in a trap but not Queue#pop.
      @first_signal_token = Queue.new << true
    end

    # Installs the traps described above. The Interrupt is raised with
    # Thread#raise, so it respects the deferral in #start.
    def trap_signals
      TERMINATING_SIGNALS.each do |name|
        previous = trap(name) do
          if first_signal?
            @first_signal = name
            Thread.main.raise(Interrupt)
          elsif name != 'HUP'
            kill_children_and_exit(name)
          end
        end
        trap(name, previous) if previous == 'IGNORE'
      end
    end

    # Runs the block in a new worker thread. The Interrupt is deferred while
    # the thread is started and recorded, so #shutdown sees every started
    # thread. The thread would inherit that deferral, so it's undone inside.
    def start(&block)
      Thread.handle_interrupt(Interrupt => :never) do
        index = @threads.size
        @uncollected += 1
        @threads << Thread.new do
          # A worker's exception is re-raised by #collect; don't print it
          # twice.
          Thread.current.report_on_exception = false
          Thread.handle_interrupt(Interrupt => :immediate, &block)
        ensure
          @finished << index
        end
      end
    end

    # Waits for the threads started since the last call, yielding each
    # one's value as it finishes. Returns their values in start order.
    # Re-raises if a worker raised.
    def collect
      count = @uncollected
      @uncollected = 0
      finished = Array.new(count) do
        index = @finished.pop
        [index, @threads[index].value.tap { |value| yield value if block_given? }]
      end
      finished.sort_by(&:first).map(&:last)
    end

    # Open3.capture3, but with the agent in its own process group and
    # tracked for #shutdown while it runs, and its output read as UTF-8
    # whatever the locale. An agent spawned after shutdown has started
    # signalling gets the same signal at once.
    def capture3(env, *argv, stdin_data:)
      Open3.popen3(env, *argv, **SPAWN_OPTIONS) do |stdin, stdout, stderr, wait_thr|
        [stdout, stderr].each { |io| io.set_encoding(Encoding::UTF_8) }
        pid = wait_thr.pid
        begin
          # Read after registering; signal_children sets it before reading
          # @children, so an agent is signalled by one or the other.
          signal = @children_lock.synchronize do
            @children[pid] = true
            @stop_signal
          end
          signal_child(pid, signal) if signal
          out_reader = Thread.new { stdout.read }
          err_reader = Thread.new { stderr.read }
          begin
            stdin.write(stdin_data)
          rescue Errno::EPIPE
            nil # the agent exited without reading its input
          end
          stdin.close
          [out_reader.value, err_reader.value, wait_thr.value]
        ensure
          @children_lock.synchronize { @children.delete(pid) }
        end
      end
    end

    # Called from main's rescue Interrupt: yields so the caller can report
    # it, then stops the agents as described above. Returns once the
    # workers are done or the agents have been killed; the caller then
    # calls #exit_by_signal. A second signal meanwhile exits from the trap.
    def shutdown
      flush_stdout # dying by a signal skips this
      yield if block_given?
      signal_children('TERM')
      return if all_joined_by?(monotonic_now + @grace)

      signal_children('KILL')
      all_joined_by?(monotonic_now + 1) # let killed agents' workers clean up
    end

    # .exit_by_signal for the signal that stopped the run.
    def exit_by_signal
      self.class.exit_by_signal(@first_signal || 'INT')
    end

    # name: the signal that called it, for when it arrived together with the
    # first one, whose trap may not have set @first_signal yet.
    private def kill_children_and_exit(name)
      signal_children('KILL')
      flush_stdout
      self.class.exit_by_signal(@first_signal || name)
    end

    private def first_signal?
      @first_signal_token.pop(true)
    rescue ThreadError # already taken
      false
    end

    # Signals every running agent's process group. Callable from a trap.
    private def signal_children(signal)
      @stop_signal = signal
      children_snapshot.each { |pid| signal_child(pid, signal) }
    end

    # A snapshot, so a concurrent spawn can't modify the hash mid-iteration.
    # MRI forbids Mutex#lock in a trap, but its GVL makes Hash#keys atomic.
    # JRuby has no GVL, but its traps run in ordinary threads, which may lock.
    private def children_snapshot
      return @children.keys unless RUBY_ENGINE == 'jruby'

      @children_lock.synchronize { @children.keys }
    end

    private def signal_child(pid, signal)
      Process.kill(signal, -pid)
    rescue SystemCallError
      nil # already gone
    end

    # A hung-up terminal can make writing fail; that mustn't stop shutdown.
    private def flush_stdout
      $stdout.flush
    rescue IOError, SystemCallError
      nil
    end

    # Joins every thread until the deadline; true if all finished. A worker
    # that raised has finished (#collect reports its exception).
    private def all_joined_by?(deadline)
      @threads.map do |thread|
        thread.join([deadline - monotonic_now, 0].max)
      rescue
        true
      end.all?
    end

    private def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
