# frozen_string_literal: true

# AgentCouncil::SafeStdout — what main sets $stdout to, so that output that
# can't be written doesn't end a run.

module AgentCouncil
  # Wraps an IO, passing output and flushes through to it until one fails
  # (EPIPE once a pipe's reader has gone, as with `| head`, or a hung-up
  # terminal), then discarding output from then on. Raising would end
  # agent-council, losing run.json and the consolidation and leaving the
  # agents, in process groups of their own, running. Every write is
  # covered: MRI's buffered ones fail on a later flush (including the one
  # it makes before spawning a process, which calls flush here), JRuby's
  # unbuffered ones on the write itself. Each method is the IO's own, so
  # behaves as it does (encoding included). No lock: a trap can flush, and
  # concurrent failures at worst discard into two sinks.
  class SafeStdout
    def initialize(io)
      @io = io
    end

    %i[write puts print printf flush].each do |name|
      define_method(name) do |*args|
        result = @io.public_send(name, *args)
        { write: result, flush: self }[name] # as IO's: puts, print, and printf return nil
      rescue IOError, SystemCallError
        @io = File.open(File::NULL, 'w')
        retry
      end
    end

    def <<(object)
      write(object.to_s)
      self
    end

    def sync = @io.sync

    def sync=(value)
      @io.sync = value
    end

    def tty? = @io.tty?
    alias isatty tty?

    def fileno = @io.fileno
  end
end
