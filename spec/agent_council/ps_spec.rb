# frozen_string_literal: true

# Focused tests for lib/agent_council/ps.rb and exe/agent-council-ps. Run
# with: rspec
require 'spec_helper'
require 'open3'
require 'stringio'
require 'agent_council/ps'

RSpec.describe AgentCouncil::Ps do
  # pid ppid pgid etime time rss args. pi shows as "pi" alone, as the real
  # one does; 214 is an agent run by an interpreter, as the e2e specs' fake
  # pi is, whose system prompt mentions agent-council.
  let(:ps_output) do
    <<~PS
        1       0       1  1-00:06:30 00:00:06 15872 /sbin/init splash
      100       1     100       10:00 00:00:01  2048 -zsh
      200     100     200     1:02:03 00:00:04 81920 /home/u/.rvm/rubies/ruby-4.0.7/bin/ruby /home/u/.gem/bin/agent-council prompt.md
      211     200     211     1:02:00 00:03:12 215040 pi
      212     200     212       59:00 00:00:10 102400 claude -p --model claude-sonnet-5-5
      213     200     213       58:00 00:00:10 102400 opencode run --format json --model zai/glm-5
      214     200     214       58:00 00:00:01 40960 ruby /tmp/fake/pi -p --append-system-prompt agent-council runs you
      250     200     200       00:01 00:00:00  1024 git rev-parse HEAD
      300     211     211       00:41 00:00:02  4096 /bin/bash -c git log -p --all
      301     300     211       00:41 00:00:01  8192 git log -p --all
      400     100     400       05:00 00:00:00  1024 timeout --foreground 2h agent-council p.md
      401     400     400       05:00 00:00:01 40960 ruby -W0 exe/agent-council p.md
      500     100     500       01:00 00:00:00  2048 vim exe/agent-council
      600     100     600       00:05 00:00:00  2048 ruby exe/agent-council-ps
      700     100     700       00:09 00:00:05 409600 java -Xss2048k -cp : -Djruby.home=/j org.jruby.Main /g/bin/agent-council p.md
    PS
  end
  let(:processes) { described_class.parse_ps(ps_output) }

  def report(**options)
    described_class.report(processes, cwd: ->(_pid) { '/proj' }, **options)
  end

  it 'parses ps durations, with days and macOS fractions' do
    expect(described_class.parse_duration('1-00:06:30')).to eq(86_790)
    expect(described_class.parse_duration('1:02:03')).to eq(3723)
    expect(described_class.parse_duration('63:01.50')).to eq(3781.5)
  end

  it 'joins a command line ps split across lines, and replaces invalid bytes' do
    output = "  10   1  10  00:01 00:00:00  1024 sh -c echo\n  two\n  " \
      "11   1  11  00:01 00:00:00  1024 caf\xE9\n"
    parsed = described_class.parse_ps(output.b)
    expect(parsed.transform_values(&:args)).to eq(10 => 'sh -c echo two', 11 => 'caf�')
  end

  it 'finds agent-council runs under MRI and JRuby, and only those' do
    runs = described_class.runs(processes)
    expect(runs.map { |council, agents| [council.pid, agents.map(&:pid)] })
      .to eq([[200, [211, 212, 213, 214]], [401, []], [700, []]])
  end

  it "skips Ruby options' arguments to find the script" do
    council = ->(args) { described_class.agent_council?(described_class::Entry.new(1, 0, 1, 0, 0, 0, args)) }
    expect(['ruby -I lib exe/agent-council p.md', 'ruby -E UTF-8 -Ilib /g/agent-council',
      'ruby -- agent-council', 'java -cp : org.jruby.Main -I lib /g/bin/agent-council'].map(&council))
      .to all(be(true))
    expect(['ruby -r agent-council -e sleep', 'ruby -e agent-council', 'ruby -I agent-council x.rb',
      'ruby'].map(&council)).to all(be(false))
  end

  it 'uses the exact arguments, where /proc gives them, so a path with a space is found' do
    entry = described_class::Entry.new(1, 0, 1, 0, 0, 0, 'ruby /my gems/bin/agent-council p.md')
    expect(described_class.agent_council?(entry)).to be(false)
    entry.argv = ['ruby', '/my gems/bin/agent-council', 'p.md']
    expect(described_class.agent_council?(entry)).to be(true)
  end

  it 'reads exact arguments from /proc/PID/cmdline' do
    skip 'no /proc' unless File.exist?("/proc/#{Process.pid}/cmdline")

    cmdline = File.binread("/proc/#{Process.pid}/cmdline")
    expect(described_class.proc_argv(Process.pid)).to eq(cmdline.split("\0"))
    expect(described_class.proc_argv(0)).to be_nil
  end

  it 'takes a line too short to be a process for part of the last command line, and skips it if first' do
    expect(described_class.parse_ps("  100   1  100 \n")).to eq({})
    parsed = described_class.parse_ps("  10   1  10  00:01 00:00:00  1024 sh\n  100   1  100 \n")
    expect(parsed.transform_values(&:args)).to eq(10 => 'sh 100   1  100')
  end

  it 'prints no control characters from command lines, models, or directories' do
    processes = described_class.parse_ps(<<~PS)
      200   1 200  01:00 00:00:00 1024 ruby exe/agent-council
      211 200 211  01:00 00:00:00 1024 claude --model m\e]0;x\a
      300 211 211  00:10 00:00:00 1024 echo \e[2Jhi
    PS
    lines = described_class.report(processes, cwd: ->(_pid) { "/p\e[31m" })
    expect(lines.join).not_to match(/[[:cntrl:]]/)
    expect(lines[0]).to end_with('in /p [31m')
  end

  it 'selects runs by their own pid or an agent pid' do
    expect(described_class.runs(processes, pids: [212]).map { _1.first.pid }).to eq([200])
    expect(described_class.runs(processes, pids: [401, 999]).map { _1.first.pid }).to eq([401])
  end

  it 'names each agent by harness and, where its command line shows it, model' do
    labels = processes.values_at(211, 212, 213, 214).map do |agent|
      [described_class.harness_name(agent), described_class.model_label(agent)]
    end
    expect(labels).to eq([['pi', ''], ['claude', 'claude-sonnet-5-5'], ['opencode', 'zai / glm-5'],
      ['pi', '']])
  end

  it 'reports each agent and the commands it is running' do
    previous = described_class.parse_ps(ps_output.sub('00:03:12 215040', '00:03:11 215040'))
    lines = report(previous: previous, interval: 2, pids: [200])
    expect(lines).to eq([
      'agent-council pid 200, running 01:02:03, in /proj',
      '  - pid 211  pi  running 01:02:00  cpu 00:03:12 (50% now)  210 MB',
      '      300  00:00:41  /bin/bash -c git log -p --all',
      '          301  00:00:41  git log -p --all',
      '  - pid 212  claude  claude-sonnet-5-5  running 00:59:00  cpu 00:00:10 (0% now)  100 MB',
      '  - pid 213  opencode  zai / glm-5  running 00:58:00  cpu 00:00:10 (0% now)  100 MB',
      '  - pid 214  pi  running 00:58:00  cpu 00:00:01 (0% now)  40 MB',
      '',
    ])
  end

  it 'leaves out CPU use without an earlier snapshot, and says when no agent is running' do
    expect(report(pids: [401]))
      .to eq(['agent-council pid 401, running 00:05:00, in /proj', '  (no agents running)', ''])
    expect(report.grep(/now\)/)).to be_empty
  end

  it 'cuts long command lines to the width' do
    expect(report(width: 40, pids: [200])[2]).to eq('      300  00:00:41  /bin/bash -c git lo…')
  end

  it 'says when no run is found' do
    expect(described_class.report({})).to eq(['No running agent-council found.'])
  end

  it 'reads CPU ticks from /proc/PID/stat, whatever the command name' do
    fields = %w[S 1 1 1 0 -1 4194304 100 0 0 0 250 50 0 0 20 0 1 0]
    expect(described_class.parse_proc_stat("42 (a b) c)) #{fields.join(' ')}")).to eq(300)
    expect(described_class.parse_proc_stat('42 (truncated')).to be_nil
    expect(described_class.parse_proc_stat('42 (x) S 1')).to be_nil
  end

  it "reads this process's CPU time and working directory" do
    skip 'no /proc' unless File.exist?("/proc/#{Process.pid}/stat")

    expect(described_class.proc_cpu(Process.pid)).to be_a(Float).and(be >= 0)
    expect(described_class.proc_cpu(0)).to be_nil
    expect(described_class.process_cwd(Process.pid)).to eq(File.realpath(Dir.pwd))
  end

  it 'raises an Error when ps cannot run' do
    allow(Open3).to receive(:capture2).and_raise(Errno::ENOENT, 'ps')
    expect { described_class.ps_snapshot }.to raise_error(described_class::Error, /can't run ps/)
  end

  it 'raises an Error when ps fails' do
    allow(Open3).to receive(:capture2).and_return(['', instance_double(Process::Status, success?: false)])
    expect { described_class.ps_snapshot }.to raise_error(described_class::Error, /ps failed/)
  end

  it "asks lsof for a process's working directory where there's no /proc" do
    allow(File).to receive(:symlink?).and_return(false)
    allow(Open3).to receive(:capture2).and_return(["p42\nfcwd\nn/some dir\n",
      instance_double(Process::Status, success?: true)])
    expect(described_class.process_cwd(42)).to eq('/some dir')
    expect(Open3).to have_received(:capture2).with('lsof', '-a', '-p', '42', '-d', 'cwd', '-Fn', err: File::NULL)
  end

  it 'takes a real snapshot including this process' do
    expect(described_class.ps_snapshot).to include(Process.pid)
  end

  it 'parses its arguments, taking a watch interval only when attached' do
    expect(described_class.parse_args(%w[-w 211])).to eq([5, [211]])
    expect(described_class.parse_args(%w[-w30 211])).to eq([30.0, [211]])
    expect(described_class.parse_args(%w[--watch=.5])).to eq([0.5, []])
    expect(described_class.parse_args(%w[--watch])).to eq([5, []])
    expect do
      described_class.parse_args(%w[-x])
    end.to raise_error(described_class::UsageError, /unknown argument: -x/)
    expect { described_class.parse_args(%w[-w0]) }.to raise_error(described_class::UsageError, /more than 0/)
    expect do
      described_class.parse_args(%w[--watch=abc])
    end.to raise_error(described_class::UsageError, /"abc"/)
  end

  it 'uses a width of 100 when not writing to a terminal' do
    expect(described_class.terminal_width(StringIO.new)).to eq(100)
    terminal = instance_double(IO, tty?: true, winsize: [0, 0])
    expect(described_class.terminal_width(terminal)).to eq(100)
    terminal = instance_double(IO, tty?: true, winsize: [24, 132])
    expect(described_class.terminal_width(terminal)).to eq(132)
  end

  describe '.run' do
    let(:out) { StringIO.new }
    let(:pauses) { [] }

    def run(argv, snapshots: [processes, processes], interrupt_after: nil)
      pause = ->(seconds) do
        pauses << seconds
        raise Interrupt if interrupt_after && pauses.size > interrupt_after
      end
      described_class.run(argv, out: out, snapshot: -> { snapshots.shift || processes }, pause: pause)
    end

    it 'prints one snapshot after sampling CPU use for a second' do
      expect(run(%w[401])).to eq(0)
      expect(pauses).to eq([1])
      expect(out.string).to start_with('agent-council pid 401, running 00:05:00')
    end

    it 'exits 1 when no run is found' do
      expect(run(%w[999])).to eq(1)
      expect(out.string).to eq("No running agent-council found.\n")
    end

    it 'watching, prints the first frame before waiting the interval, then refreshes' do
      expect { run(%w[-w30 401], interrupt_after: 2) }.to raise_error(Interrupt)
      expect(pauses).to eq([1, 30, 30])
      expect(out.string.scan('every 30s; Ctrl-C to stop').size).to eq(2)
    end
  end

  describe 'exe/agent-council-ps' do
    let(:exe) { File.expand_path('../../exe/agent-council-ps', __dir__) }

    it 'prints its help' do
      out, _err, status = Open3.capture3(RbConfig.ruby, exe, '--help')
      expect(status).to be_success
      expect(out).to start_with('Usage: agent-council-ps')
    end

    it 'exits 2 with a message on a bad argument' do
      _out, err, status = Open3.capture3(RbConfig.ruby, exe, '--bogus')
      expect(status.exitstatus).to eq(2)
      expect(err).to eq(<<~ERR)
        agent-council-ps: unknown argument: --bogus
        Try 'agent-council-ps --help' for usage.
      ERR
    end
  end
end
