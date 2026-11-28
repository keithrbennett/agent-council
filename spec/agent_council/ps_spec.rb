# frozen_string_literal: true

# Focused tests for lib/agent_council/ps.rb and exe/agent-council-ps. Run
# with: rspec
require 'spec_helper'
require 'fileutils'
require 'open3'
require 'stringio'
require 'tmpdir'
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
  # A working directory with a script, bin/agent-council, in it.
  let(:dir) do
    Dir.mktmpdir(nil, tmp_root).tap do |dir|
      FileUtils.mkdir_p(File.join(dir, 'bin'))
      FileUtils.touch(File.join(dir, 'bin', 'agent-council'))
    end
  end
  let(:script) { File.join(dir, 'bin', 'agent-council') }

  after { FileUtils.rm_rf(dir) }

  # Where to make temporary directories: the system's, unless its path has
  # a space in it, which a retitled run's script's path can't have.
  def tmp_root = Dir.tmpdir.include?(' ') ? '/tmp' : Dir.tmpdir

  def report(**options)
    described_class.report(processes, cwd: ->(_pid) { '/proj' }, **options)
  end

  # An Entry, pid 1, with these ps args and, as on Linux, /proc argv (or
  # none, as on macOS).
  def entry(args, argv = nil) = described_class::Entry.new(1, 0, 1, 0, 0, 0, args, argv)

  # Whether an entry with these args and argv is a run, in dir.
  def council?(args, argv = nil, cwd: ->(_pid) { dir })
    described_class.agent_council?(entry(args, argv), cwd: cwd)
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
    run_args = ['ruby -I lib exe/agent-council p.md', 'ruby -E UTF-8 -Ilib /g/agent-council',
      'ruby -- agent-council', 'java -cp : org.jruby.Main -I lib /g/bin/agent-council',
      'ruby --backtrace-limit 20 ./agent-council p.md',
      'ruby --disable gems --parser prism exe/agent-council',
      'ruby3.4 --enable frozen-string-literal exe/agent-council',
      'java org.jruby.main.Main --disable gems exe/agent-council',
      'ruby -- -x/agent-council'] # after --, even a word starting with - is the script
    other_args = ['ruby -r agent-council -e sleep', 'ruby -e agent-council', 'ruby -I agent-council x.rb',
      'ruby', 'ruby --crash-report /tmp/agent-council other.rb', 'ruby /x/my-agent-council',
      'ruby-lsp /x/agent-council', 'java org.jruby.ext.Tool /g/bin/agent-council']
    expect(run_args.map { |args| council?(args) }).to all(be(true))
    expect(other_args.map { |args| council?(args) }).to all(be(false))
  end

  it 'finds a run under bundle exec: retitled, under MRI, or run by bundle, under JRuby' do
    # MRI: the title, which /proc's argv holds as one string, with
    # arguments that may contain "/".
    title = "#{script} /tmp/prompt.md -o tmp/council reports"
    expect(council?(title)).to be(true)
    expect(council?(title, [title])).to be(true)
    expect(council?('bin/agent-council p.md', ['bin/agent-council p.md'])).to be(true) # relative
    expect(council?('my_tool /tmp/agent-council', ['my_tool /tmp/agent-council'])).to be(false)
    # A last argument whose basename looks like an interpreter's.
    %w[/tmp/ruby /tmp/ruby3.4 jruby].each do |last|
      title = "#{script} p.md #{last}"
      expect(council?(title)).to be(true)
      expect(council?(title, [title])).to be(true)
    end
    # JRuby: bundle runs the script.
    expect(council?('java -cp : org.jruby.Main -S bundle exec ./agent-council p.md')).to be(true)
    expect(council?('ruby /g/bin/bundle exec --keep-file-descriptors exe/agent-council')).to be(true)
    expect(council?('ruby /g/bin/bundle exec --gemfile Gemfile exe/agent-council')).to be(true)
    expect(council?('ruby /g/bin/bundle exec --gemfile agent-council rake')).to be(false)
    expect(council?('ruby /g/bin/bundler exec exe/agent-council')).to be(true)
    # Versioned: Bundler's command (e.g. bundle3.4), or a version selector.
    expect(council?('java org.jruby.main.Main -S bundle _4.0.19_ exec ./agent-council p.md')).to be(true)
    expect(council?('ruby /usr/bin/bundle3.4 exec exe/agent-council')).to be(true)
    expect(council?('ruby /usr/bin/bundler3.4 _2.7.1_ exec exe/agent-council')).to be(true)
    expect(council?('ruby /g/bin/bundle _4.0.19_ exec rake')).to be(false)
    expect(council?('ruby /g/bin/bundlex exec exe/agent-council')).to be(false)
    expect(council?('ruby /g/bin/bundle exec rake')).to be(false)
    expect(council?('ruby /g/bin/bundle exec')).to be(false)
  end

  it "finds a run under RVM's executable-hooks wrapper: retitled, under MRI, or run by it, under JRuby" do
    title = '/home/u/.rvm/rubies/ruby-4.0.7/bin/ruby /home/u/.rvm/gems/ruby-4.0.7/bin/agent-council p.md'
    expect(council?(title, [title])).to be(true)
    expect(council?('ruby -I lib exe/agent-council', ['ruby -I lib exe/agent-council'])).to be(true)
    expect(council?('ruby exe/agent-council-ps', ['ruby exe/agent-council-ps'])).to be(false)
    expect(council?('ruby -e agent-council', ['ruby -e agent-council'])).to be(false)
    # Under JRuby, which doesn't retitle, it's shown as java running it.
    hooks = '/home/u/.rvm/gems/jruby-10.1.0.0/bin/jruby_executable_hooks'
    bin = '/home/u/.rvm/gems/jruby-10.1.0.0/bin'
    ["java -Xss2048k org.jruby.main.Main #{hooks} #{bin}/agent-council p.md",
      "java -cp : org.jruby.Main #{hooks} #{bin}/bundle exec #{bin}/agent-council p.md",
      'ruby /x/ruby_executable_hooks /x/agent-council'].each do |args|
      expect(council?(args, args.split)).to be(true)
    end
    ["java org.jruby.main.Main #{hooks} #{bin}/rake", "java org.jruby.main.Main #{hooks}"].each do |args|
      expect(council?(args, args.split)).to be(false)
    end
    expect(council?('vim /tmp/agent-council notes.md')).to be(false)
  end

  it "takes a Bundler title, where /proc gives it, only if it starts with an existing file's path" do
    # A script named "agent-council backup", and a program in a directory
    # named "agent-council work". Without /proc, as on macOS, they're
    # taken for runs, as documented.
    FileUtils.touch(File.join(dir, 'agent-council backup'))
    FileUtils.mkdir_p(File.join(dir, 'agent-council work', 'bin'))
    FileUtils.touch(File.join(dir, 'agent-council work', 'bin', 'tool'))
    ["#{dir}/agent-council backup p.md", "#{dir}/agent-council work/bin/tool"].each do |title|
      expect(council?(title, [title])).to be(false)
      expect(council?(title)).to be(true)
    end
    expect(council?('/nonexistent/agent-council p.md', ['/nonexistent/agent-council p.md'])).to be(false)
    # A directory named agent-council isn't the script.
    FileUtils.mkdir_p(File.join(dir, 'sub', 'agent-council'))
    title = "#{dir}/sub/agent-council p.md"
    expect(council?(title, [title])).to be(false)
    # A limitation, as documented: with a file named agent-council in the
    # same directory, they're taken for runs on Linux too.
    FileUtils.touch(File.join(dir, 'agent-council'))
    ["#{dir}/agent-council backup p.md", "#{dir}/agent-council work/bin/tool"].each do |title|
      expect(council?(title, [title])).to be(true)
    end
  end

  it "doesn't find a script whose path has a space in it, where its words are split at spaces" do
    spaced = "#{dir}/my gems/agent-council"
    FileUtils.mkdir_p(File.dirname(spaced))
    FileUtils.touch(spaced)
    expect(council?("ruby #{spaced} p.md")).to be(false) # as on macOS
    expect(council?("#{spaced} p.md", ["#{spaced} p.md"])).to be(false) # Bundler's title, under MRI
    # Under JRuby, which doesn't retitle, /proc's arguments keep it whole.
    jruby = ['java', '-cp', ':', 'org.jruby.Main', '-S', 'bundle', 'exec', spaced, 'p.md']
    expect(council?(jruby.join(' '), jruby)).to be(true)
  end

  it "finds JRuby runs by either of JRuby's main classes" do
    %w[org.jruby.Main org.jruby.main.Main].each do |main|
      expect(council?("java -Xss2048k #{main} /g/bin/agent-council p.md")).to be(true)
    end
  end

  it "doesn't fail on a path that can't be expanded, such as ~ and an unknown user" do
    title = '~nosuchuser12/agent-council p.md'
    expect(council?(title, [title], cwd: ->(_pid) { '/tmp' })).to be(false)
  end

  it "doesn't take a Bundler title's relative path for a run's if the working directory can't be read" do
    expect(council?('bin/agent-council p.md', ['bin/agent-council p.md'], cwd: ->(_pid) {})).to be(false)
  end

  it "asks for a working directory only for a Bundler title's relative path, and once per process" do
    calls = []
    cwd = ->(pid) do
      calls << pid
      dir
    end
    # Without /proc's arguments, as on macOS, none is asked for.
    described_class.runs(processes, cwd: cwd)
    expect(calls).to be_empty
    titled = described_class.parse_ps(<<~PS)
      10   1  10  01:00 00:00:00 1024 bin/agent-council p.md
      11   1  11  01:00 00:00:00 1024 #{script} p.md
      12   1  12  01:00 00:00:00 1024 ruby exe/agent-council p.md
    PS
    titled[10].argv = ['bin/agent-council p.md']
    titled[11].argv = ["#{script} p.md"]
    titled[12].argv = %w[ruby exe/agent-council p.md]
    expect(described_class.report(titled, cwd: cwd).grep(/\Aagent-council pid/).size).to eq(3)
    expect(calls).to eq([10, 11, 12]) # 10 for its title; each for its heading
  end

  it 'uses the exact arguments, where /proc gives them, so a path with a space is found' do
    process = entry('ruby /my gems/bin/agent-council p.md')
    expect(described_class.agent_council?(process)).to be(false)
    process.argv = ['ruby', '/my gems/bin/agent-council', 'p.md']
    expect(described_class.agent_council?(process)).to be(true)
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

  it "reads a model with a \"/\" whole for a harness whose --model isn't provider/model" do
    expect(described_class.model_label(entry('claude -p --model anthropic/claude-x')))
      .to eq('anthropic/claude-x')
  end

  it 'reads --provider and --model from a command line that names no harness' do
    expect(described_class.model_label(entry('node cli.js -p --model m'))).to eq('m')
  end

  # Its exact arguments, where /proc gives them, keep a word with a space whole.
  it "reads an agent's model from its exact arguments where it has them" do
    argv = ['claude', '-p', '--model', 'my model']
    expect(described_class.model_label(entry(argv.join(' '), argv))).to eq('my model')
  end

  it "names an agent by its command when it isn't a harness's" do
    agent = described_class::Entry.new(5, 1, 5, 0, 0, 2048, 'node server.js')
    expect(described_class.agent_line(agent, nil,
      0)).to eq('  - pid 5  node  running 00:00:00  cpu 00:00:00  2 MB')
  end

  it 'rounds durations to the second, as agent-council does' do
    expect(described_class.format_duration(59.6)).to eq('00:01:00')
    expect(described_class.format_duration(90_061)).to eq('25:01:01')
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
    expect(described_class.report({},
      pids: [30, 31])).to eq(['No running agent-council, or agent of one, has pid 30 or 31.'])
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
    terminal = instance_double(IO, tty?: true)
    allow(terminal).to receive(:winsize).and_raise(Errno::ENOTTY)
    expect(described_class.terminal_width(terminal)).to eq(100)
  end

  # The real thing, as far as the process tree goes: a stand-in
  # agent-council, run as the e2e specs run it, spawns an agent through
  # WorkerPool, and the agent a command. Yields the run's [council,
  # agents] and the agent's commands once all three show, or fails.
  # retitle: a title the stand-in gives itself first, as Bundler under
  # bundle exec or RVM's executable-hooks wrapper does, with SCRIPT for
  # its path.
  def with_real_run(retitle: nil)
    Dir.mktmpdir(nil, tmp_root) do |tmp|
      dir = File.join(tmp, 'council')
      Dir.mkdir(dir)
      script = File.join(dir, 'agent-council')
      File.write(script, <<~RUBY)
        #{"Process.setproctitle(#{retitle.inspect}.sub('SCRIPT', __FILE__))" if retitle}
        require 'agent_council/worker_pool'
        AgentCouncil::WorkerPool.new(grace: 1).capture3({}, 'sh', '-c', 'sleep 300; :', stdin_data: '')
      RUBY
      council = Process.spawn(RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), script,
        pgroup: true)
      agent_pids = []
      begin
        run = commands = nil
        deadline = described_class.monotonic_now + 30
        while described_class.monotonic_now < deadline
          processes = described_class.ps_snapshot
          agent_pids |= described_class.children(processes, council).map(&:pid)
          run = described_class.runs(processes, pids: [council]).first
          commands = described_class.descendants(processes, run[1].first.pid) if run && run[1].any?
          break if commands&.any?

          sleep 0.1
        end
        expect(commands).to be_truthy.and(be_any), "no run with its agent and command found: #{run.inspect}"
        yield run, commands
      ensure
        # The agents seen, and any not yet seen, each leading its group;
        # then the stand-in, which leads its own. It's stopped first, so
        # that it can't start an agent after the last look.
        begin
          Process.kill('STOP', council)
          agent_pids |= described_class.children(described_class.ps_snapshot, council).map(&:pid)
        rescue
          nil
        end
        [*agent_pids, council].each do |pid|
          Process.kill('KILL', -pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
        Process.wait(council)
      end
    end
  end

  it 'finds a real run, its agent (spawned as WorkerPool spawns one), and its command' do
    with_real_run do |(council, agents), commands|
      expect(agents.map(&:args)).to eq(['sh -c sleep 300; :'])
      expect(commands.map { |process, depth| [process.args, depth] }).to eq([['sleep 300', 1]])
      # As on macOS, with only ps's command line.
      council.argv = nil
      expect(described_class.agent_council?(council)).to be(true)
    end
  end

  {
    'as Bundler does under bundle exec'      => ['SCRIPT /tmp/p.md /tmp/ruby',
      %r{\A/\S+/council/agent-council /tmp/p.md /tmp/ruby\z}],
    "as RVM's executable-hooks wrapper does" => ['ruby SCRIPT p.md',
      %r{\Aruby /\S+/council/agent-council p.md\z}],
  }.each do |how, (retitle, shown)|
    it "finds a real run that retitled itself, #{how}" do
      skip "JRuby's setproctitle doesn't change what ps shows" if RUBY_ENGINE == 'jruby'

      with_real_run(retitle: retitle) do |(council, _agents), _commands|
        # Linux's ps shows the new title; whether others' do is unknown.
        unless File.exist?('/proc') || council.args.match?(shown)
          skip "this system's ps doesn't show a process's new title"
        end
        expect(council.args).to match(shown)
        # On Linux, /proc holds the title as one string.
        expect(council.argv).to eq([council.args]) if council.argv
      end
    end
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
      expect(out.string).to eq("No running agent-council, or agent of one, has pid 999.\n")
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

    # A ps that fails comes first on PATH; the rest of PATH stays, since
    # JRuby's launcher needs it. (ps_snapshot's spec covers a missing ps.)
    it 'exits 1 with a message when ps fails' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'ps'), "#!/bin/sh\nexit 3\n")
        File.chmod(0o755, File.join(dir, 'ps'))
        path = "#{dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}"
        _out, err, status = Open3.capture3({ 'PATH' => path }, RbConfig.ruby, exe)
        expect(status.exitstatus).to eq(1)
        expect(err).to include('agent-council-ps: ps failed')
      end
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
