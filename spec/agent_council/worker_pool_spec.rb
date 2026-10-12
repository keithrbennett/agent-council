# frozen_string_literal: true

# WorkerPool's threads, agent tracking and shutdown. The signal traps and
# end-to-end Ctrl-C behavior are covered in spec/end_to_end_spec.rb.
require 'spec_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe AgentCouncil::WorkerPool do
  let(:grace) { 1.0 }
  let(:pool) { described_class.new(grace: grace) }

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  describe '#collect' do
    it 'yields values as workers finish and returns them in start order' do
      gate = Queue.new
      pool.start { gate.pop && :first } # finishes only after :second is yielded
      pool.start { :second }
      yielded = []

      values = pool.collect do |value|
        yielded << value
        gate << true
      end

      expect(values).to eq(%i[first second])
      expect(yielded).to eq(%i[second first])
    end

    it 'waits only for threads started since the last collect' do
      pool.start { :a }
      expect(pool.collect).to eq([:a])
      pool.start { :b }
      expect(pool.collect).to eq([:b])
    end

    it 're-raises an exception from a worker' do
      pool.start { raise ArgumentError, 'boom' }
      expect { pool.collect }.to raise_error(ArgumentError, 'boom')
    end
  end

  describe '#capture3' do
    it 'returns stdout, stderr and status, feeding stdin' do
      skip 'requires a POSIX shell' if Gem.win_platform?
      script = 'cat; echo "$X" >&2; exit 3'
      out, err, status = pool.capture3({ 'X' => 'y' }, 'sh', '-c', script, stdin_data: 'in')
      expect([out, err, status.exitstatus]).to eq(['in', "y\n", 3])
    end

    it 'returns output as UTF-8 under a non-UTF-8 locale' do
      skip 'requires a POSIX shell' if Gem.win_platform?
      out, err, = with_us_ascii_locale do
        pool.capture3({}, 'sh', '-c', 'printf é; printf ✓ >&2', stdin_data: '')
      end
      expect([out, err]).to eq(%w[é ✓])
    end

    it 'runs the child in its own process group' do
      skip 'process groups are POSIX-only' if Gem.win_platform?
      out, err, status = pool.capture3({}, 'sh', '-c', 'echo $$; ps -o pgid= -p $$', stdin_data: '')
      expect(status).to be_success, err
      pid, pgid = out.split.map(&:to_i)
      expect(pgid).to eq(pid)
    end
  end

  describe '#shutdown' do
    around do |example|
      skip 'requires a POSIX shell and process groups' if Gem.win_platform?
      example.run
    ensure
      FileUtils.remove_entry(dir)
    end

    let(:dir) { Dir.mktmpdir }

    # Starts a worker that, once `gate` (if any) opens, runs a shell child
    # that runs `script`, announces itself, then sleeps. Returns the path
    # the child writes its pid to.
    def start_child(script, gate: nil)
      marker = File.join(dir, "child-#{rand(1 << 30)}")
      pool.start do
        gate&.pop
        pool.capture3({}, 'bash', '-c', "#{script}; echo $$ > #{marker}; sleep 30", stdin_data: '')
      end
      marker
    end

    def wait_for(marker)
      deadline = monotonic_now + 5
      until File.size?(marker)
        raise "timed out waiting for #{marker}" if monotonic_now > deadline

        sleep 0.02
      end
    end

    def timed_shutdown
      started = monotonic_now
      pool.shutdown
      monotonic_now - started
    end

    def termsigs = pool.collect.map { |(_, _, status)| status.termsig }

    it 'stops children with SIGTERM and returns once workers finish' do
      wait_for(start_child('true'))
      expect(timed_shutdown).to be < grace / 2
      expect(termsigs).to eq([Signal.list['TERM']])
    end

    it 'kills children that survive SIGTERM once the grace period expires' do
      wait_for(start_child("trap '' TERM"))
      expect(timed_shutdown).to be_between(grace, grace + 2)
      expect(termsigs).to eq([Signal.list['KILL']])
    end

    it 'sends SIGTERM to a child spawned after shutdown has started' do
      gate = Queue.new
      start_child('true', gate: gate)
      Thread.new do # spawn once shutdown is waiting
        sleep 0.1
        gate << true
      end

      expect(timed_shutdown).to be < grace / 2
      expect(termsigs).to eq([Signal.list['TERM']])
    end
  end
end
