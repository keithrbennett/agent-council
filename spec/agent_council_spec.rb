# frozen_string_literal: true

# Focused tests for the harness-agnostic logic in lib/agent_council.rb
# (no model calls), plus how run_agent handles each harness's output.
# Harness-specific parsing is tested in spec/agent_council/pi_harness_spec.rb
# and spec/agent_council/claude_code_harness_spec.rb. Run with: rspec

require 'spec_helper'
require 'json'
require 'shellwords'
require 'tmpdir'

RSpec.describe AgentCouncil do
  describe '.sanitize' do
    it 'keeps safe characters' do
      expect(described_class.sanitize('claude-sonnet-4-5')).to eq('claude-sonnet-4-5')
      expect(described_class.sanitize('kimi-k2.6')).to eq('kimi-k2.6')
      expect(described_class.sanitize('gpt-5.4')).to eq('gpt-5.4')
    end

    it 'replaces unsafe characters' do
      expect(described_class.sanitize('a/b')).to eq('a-b')
      expect(described_class.sanitize("a b\tc")).to eq('a-b-c')
      expect(described_class.sanitize('(x)')).to eq('x')
      expect(described_class.sanitize('.x.y.')).to eq('x.y')
    end

    it 'collapses runs of unsafe characters into one dash' do
      expect(described_class.sanitize('a//b::c')).to eq('a-b-c')
    end
  end

  describe '.query_slug' do
    [
      ['-', 'prompts/code-base-state-prompt.md', 'code-base-state'],
      ['_', 'prompts/code-base-state_prompt.md', 'code-base-state'],
    ].each do |separator, path, expected_slug|
      it "strips the #{separator}prompt suffix" do
        expect(described_class.query_slug(path)).to eq(expected_slug)
      end
    end

    it 'strips the suffix case-insensitively' do
      expect(described_class.query_slug('/tmp/Security-Review_Prompt.md')).to eq('security-review')
      expect(described_class.query_slug('/tmp/Security-Review-PROMPT.md')).to eq('security-review')
    end

    it 'strips only a trailing suffix' do
      expect(described_class.query_slug('prompt-tuning.md')).to eq('prompt-tuning')
      expect(described_class.query_slug('my-prompts.md')).to eq('my-prompts')
      expect(described_class.query_slug('a-prompt-prompt.md')).to eq('a-prompt')
    end

    it 'works for prompt files not following the convention' do
      expect(described_class.query_slug('notes.md')).to eq('notes')
      expect(described_class.query_slug('prompt')).to eq('prompt') # no extension
    end

    it "falls back to 'prompt' when nothing usable remains" do
      expect(described_class.query_slug('!!!.md')).to eq('prompt')
      expect(described_class.query_slug('_prompt.md')).to eq('prompt')
      expect(described_class.query_slug('-prompt.md')).to eq('prompt')
    end
  end

  describe '.reports_dir' do
    around do |example|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    end

    it 'is ./agent-council-reports under the working directory (the analyzed repo)' do
      expect(described_class.reports_dir).to eq(File.join(Dir.pwd, 'agent-council-reports'))
    end

    it 'resolves an explicit relative path against the current working directory' do
      expect(described_class.reports_dir('out/reports')).to eq(File.join(Dir.pwd, 'out', 'reports'))
    end

    it 'returns an explicit absolute path unchanged' do
      expect(described_class.reports_dir('/var/council')).to eq('/var/council')
    end
  end

  # Runs each example in an empty working directory with an empty, stubbed home.
  shared_context 'with isolated cwd and home' do
    let(:tmp_root) { Dir.mktmpdir }
    let(:home) { File.join(tmp_root, 'home') }
    let(:work) { File.join(tmp_root, 'work') }
    let(:home_config) { File.join(home, '.agent-council.yml') }

    around do |example|
      Dir.mkdir(home)
      Dir.mkdir(work)
      Dir.chdir(work) { example.run }
    ensure
      FileUtils.remove_entry(tmp_root)
    end

    # Stub Dir.home rather than mutating ENV['HOME'], so there is no global
    # state to restore.
    before { allow(Dir).to receive(:home).and_return(home) }
  end

  describe '.display_source_path' do
    before { allow(Dir).to receive(:home).and_return('/home/someone') }

    it 'abbreviates paths under the home directory' do
      expect(described_class.display_source_path('/home/someone/.agent-council.yml'))
        .to eq('~/.agent-council.yml')
    end

    it 'leaves other paths absolute' do
      expect(described_class.display_source_path('/srv/x/agent-council.yml'))
        .to eq('/srv/x/agent-council.yml')
    end

    it 'does not treat a sibling with the same prefix as under home' do
      expect(described_class.display_source_path('/home/someone-else/c.yml'))
        .to eq('/home/someone-else/c.yml')
    end
  end

  describe '.resolve_config_path' do
    include_context 'with isolated cwd and home'

    it 'returns the explicit path when given, even if default configs exist' do
      File.write('agent-council.yml', '')
      File.write(home_config, '')
      expect(described_class.resolve_config_path('other.yml')).to eq('other.yml')
    end

    it 'falls back to ./agent-council.yml when no path is given' do
      File.write('agent-council.yml', '')
      expect(described_class.resolve_config_path(nil)).to eq(File.join(Dir.pwd, 'agent-council.yml'))
    end

    it 'prefers ./agent-council.yml over ~/.agent-council.yml' do
      File.write('agent-council.yml', '')
      File.write(home_config, '')
      expect(described_class.resolve_config_path(nil)).to eq(File.join(Dir.pwd, 'agent-council.yml'))
    end

    it 'falls back to ~/.agent-council.yml when the cwd has no config' do
      File.write(home_config, '')
      expect(described_class.resolve_config_path(nil)).to eq(home_config)
    end

    it 'is nil when no path is given and no default config exists' do
      expect(described_class.resolve_config_path(nil)).to be_nil
    end

    it 'does not probe the root directory when Dir.home is empty' do
      allow(Dir).to receive(:home).and_return('')
      checked_paths = []
      allow(File).to receive(:file?) do |path|
        checked_paths << path
        false
      end

      expect(described_class.resolve_config_path(nil)).to be_nil
      expect(checked_paths).to eq([File.join(Dir.pwd, 'agent-council.yml')])
    end

    it 'checks only the cwd when the home directory cannot be resolved' do
      allow(Dir).to receive(:home).and_raise(ArgumentError)
      checked_paths = []
      allow(File).to receive(:file?) do |path|
        checked_paths << path
        false
      end

      expect(described_class.resolve_config_path(nil)).to be_nil
      expect(checked_paths).to eq([File.join(Dir.pwd, 'agent-council.yml')])
    end

    it 'does not look in parent directories' do
      File.write('agent-council.yml', '')
      Dir.mkdir('sub')
      Dir.chdir('sub') { expect(described_class.resolve_config_path(nil)).to be_nil }
    end
  end

  describe '.run_agent' do
    let(:agent) { { 'harness' => 'pi', 'provider' => 'p', 'model' => 'm' } }
    let(:pi_harness) { AgentCouncil::Harnesses::PiHarness }
    let(:run_dir) { Dir.mktmpdir }
    let(:scratch_dirs) { [] }

    after { FileUtils.remove_entry(run_dir) }

    # Records the scratch dir (passed to the child as TMPDIR) and leaves a
    # file in it, as a real agent would.
    def stub_capture3(stdout, status)
      allow(Open3).to receive(:capture3) do |env, *_argv, **_opts|
        scratch_dirs << env.fetch('TMPDIR')
        File.write(File.join(env.fetch('TMPDIR'), 'leftover'), 'x')
        [stdout, 'boom', status]
      end
    end

    # Config entries are validated at startup; run_agent guards direct callers.
    it 'fails an entry without a harness, spawning nothing' do
      allow(Open3).to receive(:capture3)
      _label, ok, detail =
        described_class.run_agent(agent.except('harness'), 'prompt', run_dir, 'prefix', index: 1)
      expect(ok).to be(false)
      expect(detail).to eq("config entry is missing 'harness'")
      expect(Open3).not_to have_received(:capture3)
      expect(Dir.children(run_dir)).to be_empty
    end

    describe 'under Claude Code' do
      let(:claude_agent) do
        { 'harness' => 'claude', 'provider' => 'anthropic', 'model' => 'claude-haiku-5-5' }
      end

      def claude_fixture(name)
        File.read(File.expand_path("fixtures/claude_code/#{name}.jsonl", __dir__), encoding: 'UTF-8')
      end

      it 'explains a failure that exited nonzero from its stream, not its stderr' do
        stub_capture3(claude_fixture('not_logged_in'), instance_double(Process::Status, success?: false,
          exitstatus: 1))
        _label, ok, detail = described_class.run_agent(claude_agent, 'prompt', run_dir, 'prefix', index: 1)
        expect(ok).to be(false)
        expect(detail).to eq('claude exited 1: Not logged in · Please run /login')
      end

      it 'keeps terminal escapes out of a failure, whether or not it exited 0' do
        stream = "#{JSON.generate('type' => 'result', 'is_error' => true, 'result' => "bad\e[2J\rmodel")}\n"
        stub_capture3(stream, instance_double(Process::Status, success?: false, exitstatus: 1))
        _label, _ok, detail = described_class.run_agent(claude_agent, 'prompt', run_dir, 'prefix', index: 1)
        expect(detail).to eq('claude exited 1: bad [2J model')

        stub_capture3(stream, instance_double(Process::Status, success?: true))
        _label, _ok, detail = described_class.run_agent(claude_agent, 'prompt', run_dir, 'prefix', index: 1)
        expect(detail).to eq('claude exited 0 but the agent failed: bad [2J model')
      end

      it 'still reads warnings when the stream has an invalid byte' do
        denial = { 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'echo BAD' } }
        stream = "#{JSON.generate('type' => 'result', 'is_error' => false, 'result' => 'report',
          'permission_denials' => [denial])}\n".sub('BAD', "\xFF").b
        stub_capture3(stream, instance_double(Process::Status, success?: true))
        *, warnings = described_class.run_agent(claude_agent, 'prompt', run_dir, 'prefix', index: 1)
        expect(warnings).to eq(["Claude Code refused 1 tool call: Bash (echo \uFFFD)"])
      end

      # Returned as recorded in run.json, so no reader of it gets the escape.
      it "returns warnings with no terminal escapes from a refused call's command" do
        denial = { 'tool_name' => 'Bash', 'tool_input' => { 'command' => "echo \e[2Jx" } }
        stream = "#{JSON.generate('type' => 'result', 'is_error' => false, 'result' => 'report',
          'permission_denials' => [denial])}\n"
        stub_capture3(stream, instance_double(Process::Status, success?: true))
        *, warnings = described_class.run_agent(claude_agent, 'prompt', run_dir, 'prefix', index: 1)
        expect(warnings).to eq(['Claude Code refused 1 tool call: Bash (echo [2Jx)'])
      end

      # Returned, not printed: run_agent runs in a worker thread.
      it 'keeps the report of an agent with refused tool calls, returning a warning of them' do
        stub_capture3(claude_fixture('denied'), instance_double(Process::Status, success?: true))
        _label, ok, filename, _usage, warnings = nil
        expect do
          _label, ok, filename, _usage, warnings =
            described_class.run_agent(claude_agent, 'prompt', run_dir, 'prefix', index: 1)
        end.to output('').to_stdout.and output('').to_stderr
        expect(ok).to be(true)
        expect(filename).to eq('prefix_01_claude_anthropic_claude-haiku-5-5.md')
        expect(warnings).to eq(['Claude Code refused 1 tool call: Bash (cat README.md)'])
      end

      # So report readers, and the consolidator, which reads the reports, see them.
      it "passes the warnings to the header, for the report's byline" do
        stub_capture3(claude_fixture('denied'), instance_double(Process::Status, success?: true))
        header = ->(fields) { described_class.byline_table(fields, claude_agent) }
        _label, ok, filename =
          described_class.run_agent(claude_agent, 'prompt', run_dir, 'prefix', header: header)
        expect(ok).to be(true)
        expect(File.read(File.join(run_dir, filename)))
          .to include('| warnings | Claude Code refused 1 tool call: Bash (cat README.md) |')
      end

      it 'treats a harness returning nil for its warnings as having none' do
        stub_capture3(claude_fixture('success'), instance_double(Process::Status, success?: true))
        allow(AgentCouncil::Harnesses::ClaudeCodeHarness).to receive(:warnings).and_return(nil)
        _label, ok, _filename, _usage, warnings =
          described_class.run_agent(claude_agent, 'prompt', run_dir, 'prefix', index: 1)
        expect(ok).to be(true)
        expect(warnings).to eq([])
      end

      it "returns a failed agent's warnings, since they may be why it failed" do
        denial = { 'tool_name' => 'Bash', 'tool_input' => { 'command' => 'git diff' } }
        stream = "#{JSON.generate('type' => 'result', 'is_error' => true,
          'errors' => ['Reached maximum number of turns (3)'], 'permission_denials' => [denial] * 3)}\n"
        stub_capture3(stream, instance_double(Process::Status, success?: false, exitstatus: 1))
        _label, ok, detail, _usage, warnings =
          described_class.run_agent(claude_agent, 'prompt', run_dir, 'prefix', index: 1)
        expect(ok).to be(false)
        expect(detail).to eq('claude exited 1: Reached maximum number of turns (3)')
        expect(warnings).to eq(['Claude Code refused 3 tool calls: Bash (git diff)'])
      end

      it 'returns no warnings for a failed agent with nothing refused' do
        stub_capture3(claude_fixture('not_logged_in'), instance_double(Process::Status, success?: false,
          exitstatus: 1))
        result = described_class.run_agent(claude_agent, 'prompt', run_dir, 'prefix', index: 1)
        expect(result.size).to eq(5)
        expect(result.last).to eq([])
      end

      it 'keeps an agent whose report is saved a success when its warnings cannot be read' do
        stub_capture3(claude_fixture('success'), instance_double(Process::Status, success?: true))
        allow(AgentCouncil::Harnesses::ClaudeCodeHarness).to receive(:warnings)
          .and_raise(TypeError, "bad\e[2J\nx")
        _label, ok, _filename, _usage, warnings =
          described_class.run_agent(claude_agent, 'prompt', run_dir, 'prefix', index: 1)
        expect(ok).to be(true)
        expect(warnings).to eq(["could not read the agent's warnings (TypeError: bad [2J x)"])
      end
    end

    it "runs and reads the output of the agent's own harness, naming it in the filename and front matter" do
      other = Module.new do
        const_set(:NAME, 'other')
        module_function def argv(provider, model) = ['sh', '-c', "echo #{provider}-#{model}"]
        module_function def usage(_stdout) = { 'input' => 1, 'output' => 2 }
        module_function def error_message(_stdout) = nil
        module_function def final_response(stdout) = "answer from #{stdout.strip}"
        module_function def warnings(_stdout) = []
        module_function def exit_detail(_stdout, stderr) = stderr
      end
      stub_const('AgentCouncil::Harnesses::BY_NAME', { 'pi' => AgentCouncil::Harnesses::PiHarness,
        'other' => other })

      _label, ok, filename, usage = described_class.run_agent(agent.merge('harness' => 'other'), 'prompt',
        run_dir, 'prefix', index: 1)

      expect(ok).to be(true), filename
      expect(filename).to eq('prefix_01_other_p_m.md')
      expect(usage).to eq({ 'input' => 1, 'output' => 2 })
      fields, body = described_class.parse_front_matter(File.read(File.join(run_dir, filename)))
      expect(fields['harness']).to eq('other')
      expect(body).to eq("answer from p-m\n")
    end

    it "sets the scratch dir as the agent's TMPDIR and CLAUDE_CODE_TMPDIR, and nothing else" do
      envs = []
      allow(Open3).to receive(:capture3) do |env, *_argv, **_opts|
        envs << env
        ['', '', instance_double(Process::Status, success?: true)]
      end
      allow(pi_harness).to receive_messages(error_message: nil, final_response: 'answer')
      described_class.run_agent(agent, 'prompt', run_dir, 'prefix')
      expect(envs.size).to eq(1)
      expect(envs.first.keys).to contain_exactly('TMPDIR', 'CLAUDE_CODE_TMPDIR')
      expect(envs.first['CLAUDE_CODE_TMPDIR']).to eq(envs.first['TMPDIR'])
      expect(File.basename(envs.first['TMPDIR'])).to start_with('agent-council-')
      expect(File.dirname(envs.first['TMPDIR'])).to eq(File.realpath(Dir.tmpdir)).or eq(Dir.tmpdir)
    end

    it 'deletes the scratch dir after a successful agent' do
      stub_capture3('', instance_double(Process::Status, success?: true))
      allow(pi_harness).to receive_messages(error_message: nil, final_response: 'answer')

      _label, ok, = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')

      expect(ok).to be(true)
      expect(scratch_dirs.size).to eq(1)
      expect(File).not_to exist(scratch_dirs.first)
    end

    it 'gives the header its HH:MM:SS duration and usage, keeping them out of the front matter' do
      stub_capture3('', instance_double(Process::Status, success?: true))
      usage = { 'input' => 5, 'output' => 6 }
      allow(pi_harness).to receive_messages(error_message: nil, final_response: 'answer',
        usage: usage)
      header_fields = nil
      header = ->(run_fields) { (header_fields = run_fields) && 'HEADER' }

      _label, ok, filename = described_class.run_agent(agent, 'prompt', run_dir, 'prefix', header: header)

      expect(ok).to be(true)
      expect(header_fields['duration']).to match(/\A\d\d:\d\d:\d\d\z/)
      expect(header_fields['usage']).to eq(usage)
      fields, body = described_class.parse_front_matter(File.read(File.join(run_dir, filename)))
      expect(fields.keys).to contain_exactly('harness', 'provider', 'model')
      expect(body).to eq("HEADER\nanswer\n")
    end

    it 'fails rather than replace an existing report' do
      stub_capture3('', instance_double(Process::Status, success?: true))
      allow(pi_harness).to receive_messages(error_message: nil, final_response: 'answer')
      File.write(File.join(run_dir, 'taken.md'), 'earlier')

      _label, ok, detail = described_class.run_agent(agent, 'prompt', run_dir, 'prefix', filename: 'taken.md')

      expect(ok).to be(false)
      expect(detail).to start_with('Errno::EEXIST')
      expect(File.read(File.join(run_dir, 'taken.md'))).to eq('earlier')
    end

    it 'returns the harness usage' do
      stub_capture3('', instance_double(Process::Status, success?: true))
      usage = { 'input' => 5, 'output' => 6, 'cache_read' => 0, 'cache_write' => 0 }
      allow(pi_harness).to receive_messages(error_message: nil, final_response: 'answer',
        usage: usage)

      _label, ok, _filename, returned = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')

      expect(ok).to be(true)
      expect(returned).to eq(usage)
    end

    it 'returns the usage of a failed agent too' do
      stub_capture3('', instance_double(Process::Status, success?: false, exitstatus: 1))
      allow(pi_harness).to receive(:usage).and_return({ 'input' => 5, 'output' => 6 })

      _label, ok, _detail, usage = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')

      expect(ok).to be(false)
      expect(usage).to eq({ 'input' => 5, 'output' => 6 })
    end

    it "cuts a failure's reason to 300 characters, and gives one when cleanup leaves none" do
      status = instance_double(Process::Status, success?: false, exitstatus: 1)
      detail_for = ->(stderr) {
        allow(Open3).to receive(:capture3).and_return(['', stderr, status])
        described_class.run_agent(agent, 'prompt', run_dir, 'prefix')[2]
      }
      expect(detail_for.call("#{'e' * 500}\n")).to eq("pi exited 1: #{'e' * 300}...")
      expect(detail_for.call("\e\a\n")).to eq('pi exited 1: no error output')
    end

    it 'explains a failure whose stderr has an invalid byte' do
      allow(Open3).to receive(:capture3)
        .and_return(['', "boom \xFF\n".b, instance_double(Process::Status, success?: false, exitstatus: 1)])
      _label, ok, detail = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')
      expect(ok).to be(false)
      expect(detail).to eq("pi exited 1: boom \uFFFD")
    end

    it 'reports an exception as a failure on one line, with no terminal escapes' do
      allow(Open3).to receive(:capture3).and_raise(IOError, "broke\e[2J\nhere")
      _label, ok, detail = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')
      expect(ok).to be(false)
      expect(detail).to eq('IOError: broke [2J here')
    end

    it "cuts an exception's reason to 300 characters" do
      allow(Open3).to receive(:capture3).and_raise(IOError, 'x' * 1000)
      detail = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')[2]
      expect(detail).to eq("IOError: #{'x' * 291}...")
    end

    it 'deletes the scratch dir after a failed agent' do
      stub_capture3('', instance_double(Process::Status, success?: false, exitstatus: 1))

      _label, ok, detail = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')

      expect(ok).to be(false)
      expect(detail).to include('exited 1: boom')
      expect(File).not_to exist(scratch_dirs.first)
    end

    it 'reads harness output as UTF-8 under a non-UTF-8 locale, without a pool' do
      message = { role: 'assistant', content: [{ type: 'text', text: 'Résumé ✓' }] }
      event = { type: 'message_end', message: message }
      allow(pi_harness).to receive(:argv)
        .and_return(['sh', '-c', "printf '%s\\n' #{Shellwords.escape(JSON.generate(event))}"])

      _label, ok, detail = with_us_ascii_locale do
        described_class.run_agent(agent, 'prompt', run_dir, 'prefix')
      end

      expect(ok).to be(true), detail
      expect(File.read(File.join(run_dir, detail), encoding: 'UTF-8')).to include('Résumé ✓')
    end

    it 'fails, saving no report, when the final message was cut off' do
      message = { role: 'assistant', content: [{ type: 'text', text: 'cut o' }], stopReason: 'length' }
      event = { type: 'message_end', message: message }
      allow(pi_harness).to receive(:argv)
        .and_return(['sh', '-c', "printf '%s\\n' #{Shellwords.escape(JSON.generate(event))}"])

      _label, ok, detail = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')

      expect(ok).to be(false)
      expect(detail).to include('the agent failed', 'length')
      expect(Dir.children(run_dir)).to be_empty
    end

    # As when a dying child writes into the dir while it's being removed.
    it 'ignores errors removing the scratch dir' do
      skip 'root can remove an unwritable dir' if Process.uid.zero?
      allow(Open3).to receive(:capture3) do |env, *_argv, **_opts|
        scratch_dirs << env.fetch('TMPDIR')
        locked = File.join(env.fetch('TMPDIR'), 'locked')
        FileUtils.mkdir_p(File.join(locked, 'sub'))
        File.chmod(0o500, locked)
        ['', '', instance_double(Process::Status, success?: true)]
      end
      allow(pi_harness).to receive_messages(error_message: nil, final_response: 'answer')

      _label, ok, detail = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')

      expect(ok).to be(true), detail
      expect(File).to exist(File.join(scratch_dirs.first, 'locked')) # removal did fail
    ensure
      scratch_dirs.each do |dir|
        File.chmod(0o700, File.join(dir, 'locked')) if File.exist?(File.join(dir, 'locked'))
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe '.env_options' do
    def env_options(value) = described_class.env_options(described_class::ENV_OPTS_VAR => value)

    it 'returns an empty array when AGENT_COUNCIL_OPTS is unset or blank' do
      expect(described_class.env_options({})).to eq([])
      expect(env_options('   ')).to eq([])
    end

    it 'shell-splits AGENT_COUNCIL_OPTS' do
      expect(env_options('--output-dir "tmp/reports dir" --version'))
        .to eq(['--output-dir', 'tmp/reports dir', '--version'])
    end

    it 'raises a friendly error when AGENT_COUNCIL_OPTS is malformed' do
      expect { env_options('--output-dir "') }
        .to raise_error(ArgumentError, /Invalid AGENT_COUNCIL_OPTS value/)
    end

    # Binary is how ENV tags values under LANG=C.
    %w[UTF-8 BINARY].each do |encoding|
      it "raises a friendly error when AGENT_COUNCIL_OPTS is not valid UTF-8 (tagged #{encoding})" do
        expect { env_options((+"--output-dir \xFF").force_encoding(encoding)) }
          .to raise_error(ArgumentError, /Invalid AGENT_COUNCIL_OPTS value/)
      end
    end
  end

  describe '.main' do
    include_context 'with isolated cwd and home'

    let(:pi_entry) { { 'harness' => 'pi', 'provider' => 'p', 'model' => 'm' } }

    it 'aborts on native Windows, pointing to WSL' do
      allow(described_class).to receive(:windows?).and_return(true)
      expect { described_class.main(['-h']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/does not support native Windows; please run it inside WSL\.\n.*README\.md/).to_stderr
    end

    %w[-v --version].each do |flag|
      it "prints the version and exits 0 for #{flag}, without a prompt or config" do
        expect { described_class.main([flag]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
          .and output("agent-council #{described_class::VERSION}\n").to_stdout
      end
    end

    it 'prints the gem directory and exits 0 for --gem-dir, without a prompt or config' do
      expect { described_class.main(['--gem-dir']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output("#{described_class::PROJECT_ROOT}\n").to_stdout
    end

    it 'lists --gem-dir in the -h options' do
      expect { described_class.main(['-h']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/^\s+--gem-dir\s+Show the root directory of the agent-council application/).to_stdout
    end

    it 'prints the project URL and exits 0 for --project-url, without a prompt or config' do
      expect { described_class.main(['--project-url']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output("#{described_class::PROJECT_URL}\n").to_stdout
    end

    it 'has a PROJECT_URL matching the gemspec homepage' do
      gemspec = Gem::Specification.load(File.join(described_class::PROJECT_ROOT, 'agent-council.gemspec'))
      expect(described_class::PROJECT_URL).to eq(gemspec.homepage)
    end

    it 'lists --project-url in the -h options' do
      expect { described_class.main(['-h']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/^\s+--project-url\s+Show the project's GitHub URL and exit$/).to_stdout
    end

    it 'lists --version in the -h options' do
      expect { described_class.main(['-h']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/^\s+-v, --version\s+Show the version and exit$/).to_stdout
    end

    it 'lists --consolidate in the -h options' do
      expect { described_class.main(['-h']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/^\s+--consolidate RUN_DIR\s+\S/).to_stdout
    end

    it 'lists --output-dir in the -h options' do
      expect { described_class.main(['-h']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/^\s+-o, --output-dir DIR\s+\S/).to_stdout
    end

    it 'documents AGENT_COUNCIL_OPTS in the help output' do
      expect { described_class.main(['-h']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/AGENT_COUNCIL_OPTS holds arguments inserted before the command-line ones/).to_stdout
    end

    it 'shows the current AGENT_COUNCIL_OPTS value in the help output' do
      ENV[described_class::ENV_OPTS_VAR] = '--output-dir from-env'
      expect { described_class.main(['-h']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/Currently set to: "--output-dir from-env"/).to_stdout
    end

    it 'uses AGENT_COUNCIL_OPTS as defaults for supported options' do
      File.write('p_prompt.md', 'hi')
      File.write('config.yml', YAML.dump('agents' => [pi_entry]))
      ENV[described_class::ENV_OPTS_VAR] = '--output-dir from-env'
      allow(described_class).to receive(:abort_unless_harnesses_installed)
      allow(described_class).to receive(:run_agent).and_return(['#1 p / m', true, 'report.md', nil, []])
      allow(described_class).to receive(:puts_consolidation_status)

      expect { described_class.main(['p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output.to_stdout

      expect(File).to exist(File.join('from-env', Dir.children('from-env').first))
    end

    it 'lets command-line options override AGENT_COUNCIL_OPTS defaults' do
      File.write('p_prompt.md', 'hi')
      File.write('config.yml', YAML.dump('agents' => [pi_entry]))
      ENV[described_class::ENV_OPTS_VAR] = '--output-dir from-env'
      allow(described_class).to receive(:abort_unless_harnesses_installed)
      allow(described_class).to receive(:run_agent).and_return(['#1 p / m', true, 'report.md', nil, []])
      allow(described_class).to receive(:puts_consolidation_status)

      expect { described_class.main(['--output-dir', 'from-cli', 'p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output.to_stdout

      expect(File).to exist(File.join('from-cli', Dir.children('from-cli').first))
      expect(File).not_to exist('from-env')
    end

    it 'aborts cleanly when AGENT_COUNCIL_OPTS cannot be parsed' do
      ENV[described_class::ENV_OPTS_VAR] = '--output-dir "'
      expect { described_class.main(['p_prompt.md']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/Invalid AGENT_COUNCIL_OPTS value/).to_stderr
    end

    %w[-h -v --gem-dir --project-url].each do |flag|
      it "aborts #{flag} too when AGENT_COUNCIL_OPTS is bad" do
        ENV[described_class::ENV_OPTS_VAR] = '--output-dir "'
        expect { described_class.main([flag]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/Invalid AGENT_COUNCIL_OPTS value/).to_stderr
      end
    end

    it 'shows a multi-line AGENT_COUNCIL_OPTS on one line in -h' do
      ENV[described_class::ENV_OPTS_VAR] = "--output-dir a\nx"
      expect { described_class.main(['-h']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output(/^  Currently set to: "--output-dir a\\nx"$/).to_stdout
    end

    it 'aborts --consolidate too when AGENT_COUNCIL_OPTS is bad' do
      allow(described_class).to receive(:consolidate_run)
      ENV[described_class::ENV_OPTS_VAR] = '--output-dir "'
      expect { described_class.main(['--consolidate', 'some-run']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/Invalid AGENT_COUNCIL_OPTS value/).to_stderr
      expect(described_class).not_to have_received(:consolidate_run)
    end

    ['', ' '].each do |blank|
      it "aborts on a blank --output-dir (#{blank.inspect}) instead of writing into the cwd" do
        expect { described_class.main(['-o', blank, 'p_prompt.md']) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/--output-dir needs a directory; got an empty value/).to_stderr
      end
    end

    {
      'names an existing file'    => 'afile',
      'is under an existing file' => 'afile/sub/dir',
    }.each do |situation, dir|
      it "aborts before checking the prompt when --output-dir #{situation}" do
        File.write('afile', '')
        expect { described_class.main(['-o', dir, 'missing_prompt.md']) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output("Output dir #{dir} can't be created: afile is not a directory\n").to_stderr
      end
    end

    it 'aborts when --output-dir names an unknown user home' do
      expect { described_class.main(['-o', '~no-such-user-agent-council/x', 'p_prompt.md']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/Invalid --output-dir ~no-such-user-agent-council\/x: /).to_stderr
    end

    it 'aborts with a message, not a backtrace, when the run dir cannot be created' do
      File.write('p_prompt.md', 'hi')
      File.write('config.yml', YAML.dump('agents' => [pi_entry]))
      allow(described_class).to receive(:abort_unless_harnesses_installed)
      allow(described_class).to receive(:claim_run_dir).and_raise(Errno::EACCES, 'out')
      expect { described_class.main(['-o', 'out', 'p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output("Cannot create a run dir under out: Permission denied - out\n").to_stderr
    end

    it 'aborts with a pointer to the packaged sample configs when no config exists' do
      File.write('p_prompt.md', 'hi')
      samples = File.join(described_class::EXAMPLES_DIR, 'configs')
      expect { described_class.main(['p_prompt.md']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(a_string_starting_with(
          "No config file given, and neither ./agent-council.yml nor ~/.agent-council.yml exists.\n"
        ).and(including("Sample configs: #{samples}\n",
          'Minimal config: agents: [{harness: pi, provider: ..., model: ...}]'))).to_stderr
      expect(File).not_to exist('agent-council-reports')
    end

    {
      'the prompt is named like the format addendum' =>
        ['analyst_format.md', 'config.yml', 'prompt analyst_format.md, config config.yml'],
      'the prompt and config share a file name'      =>
        ['p/same.yml', 'c/same.yml', 'prompt same.yml, config same.yml'],
    }.each do |situation, (prompt, config, names)|
      it "aborts before creating a run dir when #{situation}" do
        FileUtils.mkdir_p(%w[p c])
        File.write(prompt, 'hi')
        File.write(config, YAML.dump('agents' => [pi_entry]))
        expect { described_class.main([prompt, config]) }
          .to raise_error(SystemExit)
          .and output(/need different file names, since all three are copied into the run dir: #{names}, /)
          .to_stderr
        expect(File).not_to exist('agent-council-reports')
      end
    end

    it 'aborts before creating a run dir when the prompt is named like the reviews dir' do
      File.write('reviews', 'hi')
      File.write('c.yml', YAML.dump('agents' => [pi_entry]))
      expect { described_class.main(['reviews', 'c.yml']) }
        .to raise_error(SystemExit)
        .and output(/The prompt can't be named reviews/).to_stderr
      expect(File).not_to exist('agent-council-reports')
    end

    it 'aborts before creating a run dir when the harness executable is not on PATH, naming it once' do
      File.write('p_prompt.md', 'hi')
      agents = Array.new(2) { { 'harness' => 'pi', 'provider' => 'p', 'model' => 'm' } }
      File.write('config.yml', YAML.dump('agents' => agents))
      Dir.mkdir('empty-bin')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('PATH', '').and_return(File.expand_path('empty-bin'))
      expect { described_class.main(['p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit)
        .and output(a_string_matching(/pi executable not found; is `pi` installed.*\n.*Prerequisites/)
          .and(satisfy { |err| err.scan('executable not found').size == 1 })).to_stderr
      expect(File).not_to exist('agent-council-reports')
    end

    it 'leaves a consolidator: false, which means none, out of the executable check' do
      agent = { 'harness' => 'pi', 'provider' => 'p', 'model' => 'm' }
      File.write('p_prompt.md', 'hi')
      File.write('config.yml', YAML.dump('agents' => [agent], 'consolidator' => false))
      allow(described_class).to receive(:abort_unless_harnesses_installed).and_raise(SystemExit)
      expect { described_class.main(['p_prompt.md', 'config.yml']) }.to raise_error(SystemExit)
      expect(described_class).to have_received(:abort_unless_harnesses_installed).with([agent])
    end

    it 'checks the executable of every harness the config uses, naming each missing one' do
      other = Module.new.tap { |m| m.const_set(:NAME, 'other-harness') }
      stub_const('AgentCouncil::Harnesses::BY_NAME', { 'pi' => AgentCouncil::Harnesses::PiHarness,
        'other' => other })
      File.write('p_prompt.md', 'hi')
      agent = { 'harness' => 'other', 'provider' => 'p', 'model' => 'm' }
      consolidator = { 'harness' => 'pi', 'provider' => 'p', 'model' => 'm' }
      File.write('config.yml', YAML.dump('agents' => [agent], 'consolidator' => consolidator))
      Dir.mkdir('empty-bin')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('PATH', '').and_return(File.expand_path('empty-bin'))
      expect { described_class.main(['p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit)
        .and output(/other-harness executable not found.*\npi executable not found/).to_stderr
    end

    it 'aborts naming every bad entry and the keys each lacks, then what every entry needs' do
      File.write('p_prompt.md', 'hi')
      agents = [pi_entry, { 'model' => 'm' }, { 'harness' => 'pi', 'model' => 'm' }]
      File.write('config.yml', YAML.dump('agents' => agents, 'consolidator' => pi_entry.except('harness')))
      expect { described_class.main(['p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit)
        .and output(<<~ERR).to_stderr
          'agents' entry #2 in config.yml is missing 'harness' and 'provider'
          'agents' entry #3 in config.yml is missing 'provider'
          'consolidator' in config.yml is missing 'harness'
          Every entry needs 'harness', 'provider', and 'model' (harness: pi, claude).
        ERR
      expect(File).not_to exist('agent-council-reports')
    end

    # A config that names some harnesses isn't a 0.1.0 one; it may have a typo.
    it 'gives the 0.1.0 hint only when no entry names a harness' do
      File.write('p_prompt.md', 'hi')
      harnessless = pi_entry.except('harness')
      File.write('config.yml', YAML.dump('agents' => [harnessless, harnessless.dup]))
      expect { described_class.main(['p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit)
        .and output(a_string_ending_with("claude).\n#{described_class::MISSING_HARNESS_HINT}\n"))
        .to_stderr
    end

    {
      'no agents key'        => [{}, "No 'agents' list in config.yml"],
      'agents as a mapping'  => [{ 'agents' => { 'harness' => 'pi' } },
        "'agents' in config.yml must be a list of entries, but is a mapping"],
      'an empty agents list' => [{ 'agents' => [] }, "'agents' in config.yml is an empty list"],
    }.each do |situation, (config, message)|
      it "aborts on #{situation}, saying what is wrong" do
        File.write('p_prompt.md', 'hi')
        File.write('config.yml', YAML.dump(config))
        expect { described_class.main(['p_prompt.md', 'config.yml']) }
          .to raise_error(SystemExit)
          .and output(a_string_including(message)).to_stderr
      end
    end

    it 'aborts on a consolidator given as a list, naming its key' do
      File.write('p_prompt.md', 'hi')
      entry = { 'harness' => 'pi', 'provider' => 'p', 'model' => 'm' }
      File.write('config.yml', YAML.dump('agents' => [entry], 'consolidator' => [entry.dup]))
      expect { described_class.main(['p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit)
        .and output(/\A'consolidator' in config\.yml must be a mapping giving .*, but is a list\n\z/)
        .to_stderr
    end

    it 'aborts on an agent with an unknown harness, naming the agent' do
      File.write('p_prompt.md', 'hi')
      agent = { 'harness' => 'nope', 'provider' => 'p', 'model' => 'm' }
      File.write('config.yml', YAML.dump('agents' => [agent]))
      expect { described_class.main(['p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit)
        .and output(/'agents' entry #1 in config\.yml names an unknown harness, "nope"/).to_stderr
      expect(File).not_to exist('agent-council-reports')
    end

    it 'aborts on an unknown harness, listing the known ones' do
      File.write('p_prompt.md', 'hi')
      File.write('config.yml', YAML.dump('agents' => [pi_entry],
        'consolidator' => { 'harness' => 'nope', 'provider' => 'p', 'model' => 'm' }))
      expect { described_class.main(['p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit)
        .and output(/'consolidator' in config\.yml names an unknown harness, "nope" \(known: pi[,)]/)
        .to_stderr
      expect(File).not_to exist('agent-council-reports')
    end
  end

  describe '.main --consolidate' do
    include_context 'with isolated cwd and home'

    let(:run_dir) { 'agent-council-reports/2026-09-03/09-14-02' }
    let(:consolidator_config) do
      { 'consolidator' => { 'harness' => 'pi', 'provider' => 'c', 'model' => 'cm' } }
    end
    let(:analyst_fields) do
      { 'role' => 'analyst', 'query' => 'review', 'prompt_file' => 'review_prompt.md',
        'config_file' => 'config.yml', 'run_stamp' => '2026-09-03-09-14-02',
        'provider' => 'p', 'model' => 'm' }
    end

    # A run dir as a normal run leaves it: prompt and config copies, and one
    # analyst report.
    def write_run(fields: analyst_fields, config: consolidator_config)
      FileUtils.mkdir_p(File.join(run_dir, 'reviews'))
      File.write(File.join(run_dir, 'review_prompt.md'), 'Question?')
      File.write(File.join(run_dir, 'config.yml'), YAML.dump(config))
      File.write(File.join(run_dir, 'reviews', 'a.md'), described_class.with_front_matter(fields, 'findings'))
    end

    def expect_abort(message)
      expect { described_class.main(['--consolidate', run_dir]) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(message).to_stderr
    end

    it 'aborts when the run dir does not exist' do
      expect_abort(/Run dir not found/)
    end

    it 'aborts when the run dir has no analyst reports' do
      FileUtils.mkdir_p(run_dir)
      expect_abort(/No analyst reports found/)
    end

    it 'aborts when the reports predate --consolidate (no prompt_file, config_file, run_stamp, or query)' do
      write_run(fields: analyst_fields.except('prompt_file', 'config_file', 'run_stamp'))
      expect_abort(/runs made before --consolidate existed cannot be consolidated/)
    end

    it 'takes the run fields from a later report when the first lacks them' do
      write_run(fields: analyst_fields.except('prompt_file', 'config_file', 'run_stamp', 'query'))
      File.write(File.join(run_dir, 'reviews', 'b.md'),
        described_class.with_front_matter(analyst_fields.merge('model' => 'm2'), 'findings'))
      existing = File.join(run_dir, '2026-09-03-09-14-02_review_consolidated_pi_c_cm.md')
      File.write(existing, 'earlier')
      expect_abort(/Consolidated report already exists/)
    end

    %w[findings meta].each do |part|
      it "aborts when the report's #{part} file already exists, before any model call" do
        write_run
        File.write(File.join(run_dir, "2026-09-03-09-14-02_review_consolidated_pi_c_cm_#{part}.md"),
          'earlier')
        expect(described_class).not_to receive(:run_consolidation)
        expect_abort(/Consolidated report already exists: .*_#{part}\.md/)
      end
    end

    it 'lists every existing report file, with the plural wording' do
      write_run
      names = %w[_findings _meta].map { |part| "2026-09-03-09-14-02_review_consolidated_pi_c_cm#{part}.md" }
      names.each { |name| File.write(File.join(run_dir, name), 'earlier') }
      expect_abort(/already exists: .*_findings\.md, .*_meta\.md\nRename or delete all of them/)
    end

    it 'aborts when query is missing' do
      write_run(fields: analyst_fields.except('query'))
      expect_abort(/lack prompt_file, config_file, run_stamp, or query/)
    end

    %w[prompt_file config_file].each do |key|
      it "aborts when #{key} is not a bare file name, rather than read outside the run dir" do
        write_run(fields: analyst_fields.merge(key => '../secret.md'))
        expect_abort(/Invalid #{key} in .*: "\.\.\/secret\.md"/)
      end

      it "aborts cleanly when #{key} contains a null byte" do
        write_run(fields: analyst_fields.merge(key => "a\0b.md"))
        expect_abort(/Invalid #{key} in .*: "a\\u0000b\.md"/)
      end
    end

    { 'run_stamp' => '../../escaped', 'query' => 'x/../../escaped' }.each do |key, value|
      it "aborts when #{key} would put the report outside the run dir, before any model call" do
        write_run(fields: analyst_fields.merge(key => value))
        expect(described_class).not_to receive(:run_consolidation)
        expect_abort(/Invalid run_stamp or query in /)
        expect(Dir.glob('**/*escaped*', base: '.')).to be_empty
      end
    end

    it 'aborts cleanly when run_stamp contains a null byte' do
      write_run(fields: analyst_fields.merge('run_stamp' => "2026\0"))
      expect_abort(/Invalid run_stamp or query in /)
    end

    it 'aborts when the consolidation template is missing' do
      write_run
      stub_const("#{described_class}::CONSOLIDATE_PROMPT_PATH", File.expand_path('missing.md'))
      expect_abort(/Consolidation template missing: .*missing\.md/)
    end

    it 'aborts when the prompt copy is empty' do
      write_run
      File.write(File.join(run_dir, 'review_prompt.md'), '')
      expect_abort(/Prompt copy is empty: .*review_prompt\.md/)
    end

    ['', '.', '..'].each do |name|
      it "aborts when prompt_file is #{name.inspect}" do
        write_run(fields: analyst_fields.merge('prompt_file' => name))
        expect_abort(/Invalid prompt_file in .*: #{Regexp.escape(name.inspect)}/)
      end
    end

    it 'aborts when the prompt copy is missing' do
      write_run
      File.delete(File.join(run_dir, 'review_prompt.md'))
      expect_abort(/Prompt copy not found: .*review_prompt\.md/)
    end

    it 'aborts when the config copy is missing' do
      write_run
      File.delete(File.join(run_dir, 'config.yml'))
      expect_abort(/Config copy not found: .*config\.yml/)
    end

    it 'aborts when the config copy is not valid YAML' do
      write_run
      File.write(File.join(run_dir, 'config.yml'), "consolidator: [oops\n")
      expect_abort(/Invalid YAML in .*config\.yml/)
    end

    it 'aborts when the consolidator entry is malformed' do
      write_run(config: { 'consolidator' => { 'harness' => 'pi', 'provider' => 'c' } })
      expect_abort("'consolidator' in #{run_dir}/config.yml is missing 'model'\n")
    end

    it "suggests 'harness: pi' for a consolidator from before the 'harness' key" do
      write_run(config: { 'consolidator' => { 'provider' => 'c', 'model' => 'cm' } })
      expect_abort(/is missing 'harness'\nEvery entry needs .*\nIf this run predates the 'harness' key, /)
    end

    it "suggests 'harness: pi' for a blank harness too, but not for a named one" do
      write_run(config: { 'consolidator' => { 'harness' => ' ', 'provider' => 'c', 'model' => 'cm' } })
      expect_abort(/gives a blank 'harness'\n.*\n.*'harness: pi' to the copy/)
      write_run(config: { 'consolidator' => { 'harness' => 'pi', 'provider' => 'c' } })
      expect_abort(satisfy { |err| err.include?("is missing 'model'") && !err.include?('predates') })
    end

    it 'aborts when the consolidator names an unknown harness' do
      write_run(config: { 'consolidator' => { 'harness' => 'nope', 'provider' => 'c', 'model' => 'm' } })
      expect_abort(/'consolidator' in .*config\.yml names an unknown harness, "nope"/)
    end

    it "checks only the consolidator's harness executable, since no analysts run" do
      write_run(config: consolidator_config.merge('agents' => [{ 'harness' => 'nope', 'provider' => 'p',
        'model' => 'm' }]))
      allow(described_class).to receive(:abort_unless_harnesses_installed).and_raise(SystemExit)
      expect { described_class.main(['--consolidate', run_dir]) }.to raise_error(SystemExit)
      expect(described_class).to have_received(:abort_unless_harnesses_installed)
        .with([consolidator_config['consolidator']])
    end

    it 'aborts when the harness executable is not on PATH' do
      write_run
      Dir.mkdir('empty-bin')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('PATH', '').and_return(File.expand_path('empty-bin'))
      expect_abort(/pi executable not found/)
    end

    it 'aborts when the config copy has no consolidator' do
      write_run(config: { 'agents' => [] })
      expect_abort(/No consolidator in .*config\.yml; add one/)
    end

    # The name comes from run_stamp, not the run dir's path, which may have
    # been moved or renamed.
    it 'aborts without overwriting an existing report from the same consolidator' do
      write_run(fields: analyst_fields.merge('run_stamp' => '2026-09-03-09-14-02-2'))
      existing = File.join(run_dir, '2026-09-03-09-14-02-2_review_consolidated_pi_c_cm.md')
      File.write(existing, 'earlier')
      expect_abort(/Consolidated report already exists: #{Regexp.escape(existing)}\nRename or delete it/)
      expect(File.read(existing)).to eq('earlier')
    end

    it 'prints usage and exits 1 when given positional arguments too' do
      write_run
      expect { described_class.main(['--consolidate', run_dir, 'prompt.md']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/Usage:/).to_stderr
    end

    # Including the abbreviations OptionParser accepts.
    [
      %w[-o elsewhere],
      %w[-oelsewhere],
      %w[--output-dir=elsewhere],
      %w[--out elsewhere],
      %w[--output=elsewhere],
    ].each do |output_dir_args|
      it "aborts when given #{output_dir_args.join(' ')} too, since it writes into the run dir" do
        write_run
        expect { described_class.main(['--consolidate', run_dir, *output_dir_args]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/--output-dir .*cannot be used with --consolidate/).to_stderr
        expect(File).not_to exist('elsewhere')
      end
    end

    it 'accepts a run dir whose name starts with -o' do
      allow(described_class).to receive(:consolidate_run) { raise SystemExit, 0 }

      expect { described_class.main(['--consolidate', '-oldrun']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }

      expect(described_class).to have_received(:consolidate_run).with('-oldrun')
    end

    it 'aborts when AGENT_COUNCIL_OPTS sets --output-dir, as if it were given directly' do
      write_run
      ENV[described_class::ENV_OPTS_VAR] = '--output-dir from-env'
      expect { described_class.main(['--consolidate', run_dir]) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/--output-dir \(given directly or in AGENT_COUNCIL_OPTS\) cannot be used/).to_stderr
      expect(File).not_to exist('from-env')
    end
  end

  describe '.executable_on_path?' do
    let(:bin_dir) { Dir.mktmpdir }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('PATH', '').and_return(bin_dir)
    end

    after { FileUtils.remove_entry(bin_dir) }

    def write_file(name, mode)
      path = File.join(bin_dir, name)
      File.write(path, "#!/bin/sh\n")
      File.chmod(mode, path)
    end

    it 'finds an executable file in a PATH directory' do
      write_file('tool', 0o755)
      expect(described_class.executable_on_path?('tool')).to be(true)
    end

    it 'is false when no PATH directory has the name' do
      expect(described_class.executable_on_path?('tool')).to be(false)
    end

    it 'does not count a directory with the name' do
      Dir.mkdir(File.join(bin_dir, 'tool'))
      expect(described_class.executable_on_path?('tool')).to be(false)
    end

    it 'does not count a non-executable file' do
      write_file('tool', 0o644)
      expect(described_class.executable_on_path?('tool')).to be(false)
    end

    it 'searches every PATH directory, not just the first' do
      write_file('tool', 0o755)
      allow(ENV).to receive(:fetch).with('PATH', '').and_return("/nonexistent#{File::PATH_SEPARATOR}#{bin_dir}")
      expect(described_class.executable_on_path?('tool')).to be(true)
    end

    it 'treats empty PATH entries, including a trailing one, as the current directory' do
      write_file('tool', 0o755)
      sep = File::PATH_SEPARATOR
      Dir.chdir(bin_dir) do
        ["/nonexistent#{sep}#{sep}/also-nonexistent", "/nonexistent#{sep}"].each do |path|
          allow(ENV).to receive(:fetch).with('PATH', '').and_return(path)
          expect(described_class.executable_on_path?('tool')).to be(true), path
        end
      end
    end
  end

  describe '.report_filename' do
    let(:zai) { { 'provider' => 'zai', 'model' => 'glm-5.3' } }

    # The point of mixing harnesses: one model under each.
    it 'tells apart the same provider and model under each harness, by agent number and harness' do
      pi = { 'provider' => 'anthropic', 'model' => 'claude-opus-5-5' }
      claude = pi.merge('harness' => 'claude')
      names = [[pi, 1], [claude, 2]].map { |entry, i| described_class.report_filename('p', entry, index: i) }
      expect(names).to eq(%w[p_01_pi_anthropic_claude-opus-5-5.md p_02_claude_anthropic_claude-opus-5-5.md])
      labels = [1, 2].map { |index| described_class.agent_label('anthropic', 'claude-opus-5-5', index) }
      expect(labels).to eq(['#1 anthropic / claude-opus-5-5', '#2 anthropic / claude-opus-5-5'])
    end

    it 'carries the full timestamp and query slug, then harness/provider/model' do
      expect(described_class.report_filename('2026-09-03-19-23-57_code-base-state',
        { 'provider' => 'opencode-go', 'model' => 'kimi-k2.6' }))
        .to eq('2026-09-03-19-23-57_code-base-state_pi_opencode-go_kimi-k2.6.md')
      expect(described_class.report_filename('2026-09-03-19-23-57_prompt', zai))
        .to eq('2026-09-03-19-23-57_prompt_pi_zai_glm-5.3.md')
    end

    it 'inserts a zero-padded agent index before the harness, disambiguating repeated provider/model pairs' do
      expect(described_class.report_filename('2026-09-03-19-23-57_prompt', zai, index: 1))
        .to eq('2026-09-03-19-23-57_prompt_01_pi_zai_glm-5.3.md')
      expect(described_class.report_filename('2026-09-03-19-23-57_prompt', zai, index: 2))
        .to eq('2026-09-03-19-23-57_prompt_02_pi_zai_glm-5.3.md')
    end
  end

  describe '.claim_run_dir' do
    it 'creates the day dir and the run dir, named by the base when free' do
      Dir.mktmpdir do |dir|
        day_dir = File.join(dir, '2026-11-01')
        expect(described_class.claim_run_dir(day_dir, '01-30-00')).to eq('01-30-00')
        expect(File.directory?(File.join(day_dir, '01-30-00'))).to be(true)
      end
    end

    it 'never reuses an existing dir, suffixing -2, -3, ... instead' do
      Dir.mktmpdir do |dir|
        names = Array.new(3) { described_class.claim_run_dir(dir, '01-30-00') }
        expect(names).to eq(%w[01-30-00 01-30-00-2 01-30-00-3])
        expect(Dir.children(dir).sort).to eq(names)
      end
    end

    it 'propagates errors other than an existing dir' do
      Dir.mktmpdir do |dir|
        allow(Dir).to receive(:mkdir).and_raise(Errno::EACCES)
        expect { described_class.claim_run_dir(dir, '01-30-00') }.to raise_error(Errno::EACCES)
      end
    end
  end

  describe '.collect_reports' do
    it 'labels reports from front matter, sorted, bodies front-matter-free' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'a_pi_openai-codex_gpt-5.4.md'),
          "---\nprovider: openai-codex\nmodel: gpt-5.4\n---\n\nbody B")
        File.write(File.join(dir, 'b_pi_zai_glm-5.3.md'),
          "---\nprovider: zai\nmodel: glm-5.3\n---\n\nbody A")

        reports = described_class.collect_reports(dir).map { |label, body, _fields| [label, body] }
        expect(reports).to eq([['openai-codex / gpt-5.4', 'body B'], ['zai / glm-5.3', 'body A']])
      end
    end

    it 'skips files without parseable front matter (not our reports)' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'notes.md'), 'just markdown')
        expect(described_class.collect_reports(dir)).to eq([])
      end
    end

    it 'finds reports in a dir whose path has glob characters' do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, 'runs [old] {x}*?')
        Dir.mkdir(dir)
        File.write(File.join(dir, 'a.md'), "---\nprovider: zai\nmodel: glm-5.3\n---\n\nbody")
        expect(described_class.collect_reports(dir).map(&:first)).to eq(['zai / glm-5.3'])
      end
    end

    it 'skips files whose front matter is malformed' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'a.md'), "---\nprovider: [oops\n---\n\nbody")
        expect(described_class.collect_reports(dir)).to eq([])
      end
    end

    it 'prefixes the label with the agent index when present, distinguishing repeated provider/model pairs' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'a_01_pi_zai_glm-5.3.md'),
          "---\nprovider: zai\nmodel: glm-5.3\nagent_index: 1\n---\n\nbody A")
        File.write(File.join(dir, 'b_02_pi_zai_glm-5.3.md'),
          "---\nprovider: zai\nmodel: glm-5.3\nagent_index: 2\n---\n\nbody B")

        reports = described_class.collect_reports(dir).map { |label, body, _fields| [label, body] }
        expect(reports).to eq([['#1 zai / glm-5.3', 'body A'], ['#2 zai / glm-5.3', 'body B']])
      end
    end

    it 'includes each report\'s front matter fields' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'a.md'),
          "---\nprovider: zai\nmodel: glm-5.3\nquery: review\n---\n\nbody")
        _label, _body, fields = described_class.collect_reports(dir).first
        expect(fields).to eq('provider' => 'zai', 'model' => 'glm-5.3', 'query' => 'review')
      end
    end
  end

  describe 'front matter' do
    it 'with_front_matter and parse_front_matter round-trip' do
      content = described_class.with_front_matter({ 'provider' => 'zai', 'model' => 'glm-5.3' },
        "# Report\n\nText.")
      fields, body = described_class.parse_front_matter(content)
      expect(fields).to eq('provider' => 'zai', 'model' => 'glm-5.3')
      expect(body).to eq("# Report\n\nText.\n")
    end

    it 'round-trips list values (e.g. consolidated sources) as YAML lists' do
      content = described_class.with_front_matter({ 'sources' => ['a / one', 'b / two'] }, 'body')
      fields, = described_class.parse_front_matter(content)
      expect(fields['sources']).to eq(['a / one', 'b / two'])
    end

    it 'round-trips #N source labels, as list items and hash keys, as valid YAML' do
      fields = {
        'sources'  => ['#1 zai / glm-5.3', '#2 zai / glm-5.3'],
        'by_label' => { '#1 zai / glm-5.3' => '00:03:43', '#2 zai / glm-5.3' => '00:01:05' },
      }
      content = described_class.with_front_matter(fields, 'body')
      parsed, = described_class.parse_front_matter(content)
      expect(parsed).to eq(fields)
    end

    it 'parses unquoted ISO timestamps safely as UTC Time objects' do
      content = described_class.with_front_matter({ 'timestamp' => '2026-09-04T20:54:39' }, 'body')
      fields, = described_class.parse_front_matter(content)
      expect(fields['timestamp']).to be_a(Time)
      expect(fields['timestamp'].utc).to eq(Time.utc(2026, 9, 4, 20, 54, 39))
    end

    {
      '2026-10-12T18:02:09+07:00' => Time.utc(2026, 10, 12, 11, 2, 9),
      '2026-10-12T18:02:09-05:00' => Time.utc(2026, 10, 12, 23, 2, 9),
      '2026-10-12T18:02:09Z'      => Time.utc(2026, 10, 12, 18, 2, 9),
    }.each do |stamp, instant|
      it "parses the unquoted ISO timestamp #{stamp}, with its UTC offset, as a Time" do
        content = described_class.with_front_matter({ 'timestamp' => stamp }, 'body')
        expect(content).to include("timestamp: #{stamp}\n")
        fields, = described_class.parse_front_matter(content)
        expect(fields['timestamp']).to be_a(Time)
        expect(fields['timestamp'].utc).to eq(instant)
      end
    end

    it 'leaves consolidated_at unquoted too, so it parses as a Time' do
      fields = { 'timestamp'       => '2026-10-12T18:02:09+07:00',
                 'consolidated_at' => '2026-10-12T18:30:00+07:00' }
      content = described_class.with_front_matter(fields, 'body')
      expect(content).to include("consolidated_at: 2026-10-12T18:30:00+07:00\n")
      fields, = described_class.parse_front_matter(content)
      expect(fields['consolidated_at']).to eq(Time.new(2026, 10, 12, 18, 30, 0, '+07:00'))
    end

    it 'leaves other timestamp-like strings quoted' do
      stamp = '2026-10-12T18:02:09+07:00 or so'
      content = described_class.with_front_matter({ 'timestamp' => stamp }, 'body')
      fields, = described_class.parse_front_matter(content)
      expect(fields['timestamp']).to eq(stamp)
    end

    it 'returns no fields for plain markdown' do
      fields, = described_class.parse_front_matter("# Just markdown\n")
      expect(fields).to be_nil
    end
  end

  describe '.relative_path' do
    it 'returns paths relative to the current working directory when possible' do
      expect(described_class.relative_path(File.join(Dir.pwd, 'reports', 'x'))).to eq('reports/x')
    end
  end

  describe '.format_duration' do
    it 'formats seconds as HH:MM:SS' do
      expect(described_class.format_duration(0)).to eq('00:00:00')
      expect(described_class.format_duration(59)).to eq('00:00:59')
      expect(described_class.format_duration(61)).to eq('00:01:01')
      expect(described_class.format_duration(3661)).to eq('01:01:01')
    end

    it 'rounds fractional seconds to the nearest second' do
      expect(described_class.format_duration(1.4)).to eq('00:00:01')
      expect(described_class.format_duration(1.6)).to eq('00:00:02')
    end

    it 'lets hours exceed two digits' do
      expect(described_class.format_duration(100 * 3600)).to eq('100:00:00')
    end
  end

  describe '.format_usage' do
    it 'counts cached input as input, noting it, and shows the cost' do
      usage = { 'input' => 100, 'output' => 2500, 'cache_read' => 1_200_000, 'cache_write' => 300,
                'cost' => 1.234 }
      expect(described_class.format_usage(usage)).to eq('1.2M in (1.2M cached) / 2.5k out, $1.23')
    end

    it 'leaves out an unknown or zero cost' do
      expect(described_class.format_usage({ 'input' => 1, 'output' => 2 })).to eq('1 in / 2 out')
      expect(described_class.format_usage({ 'input' => 1, 'output' => 2, 'cost' => 0 })).to eq('1 in / 2 out')
    end

    it 'shows a cost under a cent as such, not as $0.00' do
      expect(described_class.format_usage({ 'input' => 1, 'output' => 2, 'cost' => 0.001 }))
        .to eq('1 in / 2 out, <$0.01')
    end

    it 'is nil for unknown usage' do
      expect(described_class.format_usage(nil)).to be_nil
    end
  end

  describe '.format_token_count' do
    it 'abbreviates thousands and millions to one decimal' do
      counts = [999, 1000, 45_250, 999_949, 999_950, 12_345_678]
      expect(counts.map { |n| described_class.format_token_count(n) })
        .to eq(%w[999 1.0k 45.2k 999.9k 1.0M 12.3M])
    end
  end

  describe '.sum_usage' do
    it 'sums the counts and costs, ignoring unknown usage' do
      first = { 'input' => 1, 'output' => 2, 'cache_read' => 3, 'cost' => 0.1 }
      second = { 'input' => 10, 'output' => 20, 'cache_write' => 4, 'cost' => 0.2 }
      total = described_class.sum_usage([first, nil, second])
      expect(total).to eq('input' => 11, 'output' => 22, 'cache_read' => 3, 'cache_write' => 4, 'cost' => 0.3)
    end

    it 'leaves out the cost unless every usage has one' do
      total = described_class.sum_usage([{ 'input' => 1, 'output' => 2, 'cost' => 0.1 },
        { 'input' => 1, 'output' => 2 }])
      expect(total).not_to have_key('cost')
    end

    it 'is nil when no usage is known' do
      expect(described_class.sum_usage([nil, nil])).to be_nil
    end
  end

  describe '.run_entry' do
    let(:agent) { { 'provider' => 'p', 'model' => 'm' } }

    it "records an agent's warnings, only when there are some" do
      entry = ->(**opts) { described_class.run_entry(agent, true, 'r.md', 1.0, nil, **opts) }
      expect(entry.call(warnings: ['refused'])['warnings']).to eq(['refused'])
      expect(entry.call(warnings: [])).not_to have_key('warnings')
      expect(entry.call).not_to have_key('warnings')
    end

    it "names a successful agent's report under dir, with its duration in seconds" do
      entry = described_class.run_entry(agent, true, 'a.md', 61.26, { 'input' => 1 },
        index: 2, dir: 'reviews')
      expect(entry).to eq('agent_index' => 2, 'harness' => 'pi', 'provider' => 'p', 'model' => 'm',
        'ok' => true, 'report' => 'reviews/a.md', 'duration_seconds' => 61.3, 'usage' => { 'input' => 1 })
    end

    it "records the entry's own harness" do
      entry = described_class.run_entry(agent.merge('harness' => 'other'), true, 'a.md', 1, nil)
      expect(entry['harness']).to eq('other')
    end

    it "adds the meta file to a split consolidation's entry, and only then" do
      split = described_class.run_entry(agent, true, 'f.md', 1, nil, meta_report: 'm.md')
      expect(split).to include('report' => 'f.md', 'meta_report' => 'm.md')
      expect(described_class.run_entry(agent, true, 'f.md', 1, nil, dir: 'd', meta_report: 'm.md'))
        .to include('report' => 'd/f.md', 'meta_report' => 'd/m.md')
      expect(described_class.run_entry(agent, true, 'f.md', 1, nil)).not_to include('meta_report')
      expect(described_class.run_entry(agent, false, 'boom', 1, nil, meta_report: 'm.md'))
        .not_to include('meta_report')
    end

    it "gives a failed agent's error, and null for unknown usage" do
      expect(described_class.run_entry(agent, false, 'boom', 2, nil))
        .to eq('harness' => 'pi', 'provider' => 'p', 'model' => 'm', 'ok' => false, 'error' => 'boom',
          'duration_seconds' => 2, 'usage' => nil)
    end
  end

  describe '.write_run_file' do
    let(:run_dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(run_dir) }

    it 'writes the entries and their total usage, which read_run_file reads back' do
      analysts = [{ 'ok' => true, 'usage' => { 'input' => 1, 'output' => 2 } },
        { 'ok' => false, 'usage' => nil }]
      consolidations = [{ 'ok' => true, 'usage' => { 'input' => 10, 'output' => 20 } }]
      described_class.write_run_file(run_dir, analysts, consolidations)

      data = JSON.parse(File.read(File.join(run_dir, 'run.json')))
      expect(data['total_usage']).to eq('input' => 11, 'output' => 22, 'cache_read' => 0, 'cache_write' => 0)
      expect(described_class.read_run_file(run_dir)).to eq([analysts, consolidations])
      expect(Dir.children(run_dir)).to eq(['run.json']) # no temp file left
    end

    it 'warns, rather than raises, when it cannot write the file' do
      expect { described_class.write_run_file(File.join(run_dir, 'missing'), [], []) }
        .to output(/Could not write .*run\.json/).to_stderr
    end
  end

  describe '.read_run_file' do
    it 'is nil for a missing or malformed file' do
      Dir.mktmpdir do |dir|
        expect(described_class.read_run_file(dir)).to be_nil
        File.write(File.join(dir, 'run.json'), '{"analysts": {}}')
        expect(described_class.read_run_file(dir)).to be_nil
        File.write(File.join(dir, 'run.json'), 'not json')
        expect(described_class.read_run_file(dir)).to be_nil
      end
    end
  end

  describe '.format_result_table' do
    it 'right-aligns the usage columns, listing errors below the table' do
      usage = { 'input' => 500, 'cache_read' => 1000, 'output' => 20, 'cost' => 0.123 }
      results = [['claude/opus', true, 'a.md', 61, usage], ['#2 openai/gpt-x', false, 'exit 1', 3]]
      expect(described_class.format_result_table(results)).to eq([
        '  Ok  Duration  Agent              In  Cached  Out   Cost',
        '  ✓   00:01:01  claude/opus      1.5k    1.0k   20  $0.12',
        '  ✗   00:00:03  #2 openai/gpt-x     -       -    -      -',
        '',
        '  Errors:',
        '    #2 openai/gpt-x: exit 1',
      ])
    end

    it 'lists no errors, and no report filenames, when nothing failed' do
      results = [['claude/opus', true, 'a.md', 61], ['#2 openai/gpt-x', true, 'b.md', 3]]
      expect(described_class.format_result_table(results)).to eq([
        '  Ok  Duration  Agent            In  Cached  Out  Cost',
        '  ✓   00:01:01  claude/opus       -       -    -     -',
        '  ✓   00:00:03  #2 openai/gpt-x   -       -    -     -',
      ])
    end

    it 'aligns by display width, so wide characters take two columns' do
      results = [['模型', true, 'x', 1], ['abcd', true, 'y', 1]]
      expect(described_class.format_result_table(results).drop(1)).to eq([
        '  ✓   00:00:01  模型    -       -    -     -',
        '  ✓   00:00:01  abcd    -       -    -     -',
      ])
    end
  end

  describe '.usage_summary' do
    let(:usage) { { 'input' => 1, 'output' => 2 } }

    it 'gives the total usage' do
      expect(described_class.usage_summary([usage, usage])).to eq('; 2 in / 4 out')
    end

    it 'notes how many agents the total covers when some reported no usage' do
      expect(described_class.usage_summary([usage, nil, usage])).to eq('; 2 in / 4 out (from 2 of 3 agents)')
    end

    it 'is empty when no agent reported usage' do
      expect(described_class.usage_summary([nil, nil])).to eq('')
    end
  end

  describe '.display_width' do
    it 'counts wide characters as two columns and combining marks as none' do
      expect(described_class.display_width('a c')).to eq(3)
      expect(described_class.display_width('模型x')).to eq(5)
      expect(described_class.display_width("e\u0301")).to eq(1)
      expect(described_class.display_width('✓')).to eq(1)
    end
  end

  describe '.timed' do
    it 'returns the block result and a non-negative elapsed time' do
      result, elapsed = described_class.timed { :done }
      expect(result).to eq(:done)
      expect(elapsed).to be >= 0
    end
  end

  describe '.consolidated_filename' do
    it 'is distinct from agent report filenames and self-identifying' do
      name = described_class.consolidated_filename('2026-09-03-19-23-57_review',
        { 'provider' => 'zai', 'model' => 'glm-5.3' })
      expect(name).to eq('2026-09-03-19-23-57_review_consolidated_pi_zai_glm-5.3.md')
      other = described_class.consolidated_filename('p', { 'harness' => 'other', 'provider' => 'zai',
        'model' => 'glm-5.3' }, 'meta')
      expect(other).to eq('p_consolidated_other_zai_glm-5.3_meta.md')
      # distinct from analyst filenames; the "_consolidated" infix marks its role
    end
  end

  describe '.plain_line' do
    it 'turns each run of whitespace or control characters into one space' do
      expect(described_class.plain_line("a\r\nb\e[2J c\u009b\td \n")).to eq('a b [2J c d')
    end

    it 'removes invisible format characters such as bidirectional overrides' do
      expect(described_class.plain_line("rm \u202Egnp.exe\u200B x")).to eq('rm gnp.exe x')
    end

    it 'replaces invalid bytes rather than raising' do
      expect(described_class.plain_line("bad\xFF byte".dup.force_encoding('UTF-8'))).to eq("bad\uFFFD byte")
    end

    it 'reads binary text, such as a SystemCallError message, as UTF-8' do
      expect(described_class.plain_line("caf\xC3\xA9 \xFF".b)).to eq("caf\u00E9 \uFFFD")
    end

    it 'puts each warning on its own console line, with no terminal escapes' do
      expect(described_class.warning_lines(["Bash (printf '\e]0;x\a')\nmore"]))
        .to eq(["      Warning: Bash (printf ' ]0;x ') more"])
    end
  end

  describe '.byline_table' do
    let(:gpt) { { 'provider' => 'openai', 'model' => 'gpt-x' } }

    it 'escapes backslashes too, so an escaped pipe in a command stays in the cell' do
      meta = { 'warnings' => ['Bash (grep "a\\|b" f)'] }
      expect(described_class.byline_table(meta, gpt)).to include('| warnings | Bash (grep "a\\\\\\|b" f) |')
    end

    it 'keeps carriage returns and terminal escapes out of a cell' do
      meta = { 'warnings' => ["Bash (echo a\rb\e[2J)"] }
      expect(described_class.byline_table(meta, gpt)).to include("| warnings | Bash (echo a b [2J) |\n")
    end

    it 'keeps a warning with pipes or newlines to one cell of one row' do
      meta = { 'warnings' => ['Claude Code refused 1 tool call: Bash (git log | head -5)', "two\nlines"] }
      rows = described_class.byline_table(meta, gpt).lines
      expect(rows)
        .to include("| warnings | Claude Code refused 1 tool call: Bash (git log \\| head -5); two lines |\n")
      expect(rows.size).to eq(2 + 4) # heading, rule, harness, provider, model, warnings
    end

    it 'lists the main front matter fields, leaving sources to sources_table' do
      meta = {
        'role'      => 'consolidator',
        'query'     => 'check-prev-commits',
        'timestamp' => '2026-09-03T19:23:57',
        'sources'   => ['openai / gpt-x', 'zai / glm-5.3'],
      }
      expect(described_class.byline_table(meta, { 'provider' => 'zai', 'model' => 'glm-5.3' })).to eq(
        "| Field     | Value |\n" \
        "| :-------- | :---------------------------- |\n" \
        "| role | consolidator |\n" \
        "| query | check-prev-commits |\n" \
        "| harness | pi |\n" \
        "| provider | zai |\n" \
        "| model | glm-5.3 |\n" \
        "| timestamp | 2026-09-03T19:23:57 |\n"
      )
    end

    it 'adds duration and usage rows' do
      meta = { 'role' => 'consolidator', 'duration' => '00:02:10',
        'usage' => { 'input' => 10, 'output' => 5 } }
      table = described_class.byline_table(meta, gpt)
      expect(table).to include('| duration | 00:02:10 |', '| usage | 10 in / 5 out |')
    end

    it "names the entry's harness" do
      table = described_class.byline_table({ 'role' => 'analyst' }, gpt.merge('harness' => 'other'))
      expect(table).to include('| harness | other |')
    end

    it 'adds an agent row when an agent_index is present' do
      meta = { 'role' => 'analyst', 'query' => 'review', 'timestamp' => '2026-09-03T19:23:57',
        'agent_index' => 2 }
      table = described_class.byline_table(meta, gpt)
      expect(table).to include('| agent | #2 |')
    end

    it 'omits the agent row when there is no agent_index (consolidator)' do
      meta = { 'role' => 'consolidator', 'query' => 'review', 'timestamp' => '2026-09-03T19:23:57' }
      table = described_class.byline_table(meta, gpt)
      expect(table).not_to include('| agent |')
    end
  end

  describe '.sources_table' do
    it "gives each source's duration, input (cached included), cached input, output, and cost, or -" do
      runs = {
        'a / b' => { 'duration_seconds' => 42.4,
                     'usage'            => { 'input' => 500, 'cache_read' => 1500, 'output' => 7,
                                             'cost' => 0.5 } },
        'c / d' => { 'duration_seconds' => 3, 'usage' => nil },
      }
      expect(described_class.sources_table(['a / b', 'c / d', 'e / f'], runs)).to eq(<<~TABLE)
        ### Sources

        | Source | Duration | Input | Cached | Output | Cost |
        | :----- | -------: | ----: | -----: | -----: | ---: |
        | a / b | 00:00:42 | 2.0k | 1.5k | 7 | $0.50 |
        | c / d | 00:00:03 | - | - | - | - |
        | e / f | - | - | - | - | - |
      TABLE
    end
  end

  describe '.run_consolidation' do
    let(:zai) { { 'harness' => 'pi', 'provider' => 'zai', 'model' => 'glm-5.3' } }

    it 'fails cleanly when the config entry is malformed' do
      expect(described_class.run_consolidation({ 'provider' => 'zai' }, 'prompt', '/tmp/x', 'prefix'))
        .to eq(['consolidator', false, "config entry is missing 'harness' and 'model'", nil, nil, []])
    end

    it 'fails cleanly when there are no reports to consolidate' do
      Dir.mktmpdir do |dir|
        result = described_class.run_consolidation(zai,
          'prompt', dir, 'prefix')
        expect(result[0]).to eq('zai / glm-5.3')
        expect(result[1]).to be(false)
        expect(result[2]).to include('no reports found')
      end
    end

    it 'fails cleanly when reading the reports raises' do
      Dir.mktmpdir do |dir|
        report = File.join(dir, 'reviews', 'analyst.md')
        FileUtils.mkdir_p(File.dirname(report))
        File.write(report,
          described_class.with_front_matter({ 'provider' => 'openai', 'model' => 'gpt-x' }, 'findings'))
        allow(File).to receive(:read).and_call_original
        allow(File).to receive(:read).with(report, any_args).and_raise(ArgumentError, 'invalid byte sequence')

        result = described_class.run_consolidation(zai,
          'prompt', dir, 'prefix')
        expect(result).to eq(['zai / glm-5.3', false, 'ArgumentError: invalid byte sequence', nil, nil, []])
      end
    end

    it 'writes the consolidated report at the top level of the run dir' do
      Dir.mktmpdir do |dir|
        reviews = File.join(dir, 'reviews')
        FileUtils.mkdir_p(reviews)
        File.write(File.join(reviews, 'analyst.md'),
          described_class.with_front_matter({ 'provider' => 'openai', 'model' => 'gpt-x' }, 'findings'))

        allow(Time).to receive(:now).and_return(Time.new(2026, 9, 3, 19, 40, 5, '+07:00'))
        captured = nil
        allow(described_class).to receive(:run_agent) do |_agent, _prompt, run_dir, _prefix,
          filename:, meta:, header: nil, pool: nil|
          captured = { run_dir: run_dir, filename: filename, meta: meta, header: header }
          File.write(File.join(run_dir, filename), 'consolidated body')
          ['zai / glm-5.3', true, filename, nil, []]
        end

        label = ok = nil
        expect do
          label, ok, = described_class.run_consolidation(zai,
            'prompt', dir, 'prefix', meta: {
              'query'     => 'check-prev-commits',
              'timestamp' => '2026-09-03T19:23:57',
            }, prompt_path: 'prompts/check-prev-commits_prompt.md',
            analyst_runs: [{ 'provider' => 'openai', 'model' => 'gpt-x', 'duration_seconds' => 65 }])
        end.to output(/Not splitting/).to_stderr # the stubbed report has no marker
        expect(ok).to be(true)
        expect(label).to eq('zai / glm-5.3')
        expect(captured[:run_dir]).to eq(dir)
        # written to the meta name, which keeps it taken, then renamed as it can't be split
        expect(captured[:filename]).to eq('prefix_consolidated_pi_zai_glm-5.3_meta.md')
        expect(captured[:meta]['role']).to eq('consolidator')
        expect(captured[:meta]['consolidated_at']).to eq('2026-09-03T19:40:05+07:00')
        expect(captured[:meta].keys).not_to include('source_runs')
        expect(captured[:header].call('duration' => '00:02:10')).to eq(<<~HEADER)
          # Consolidated Report

          ### Prompt: prompts/check-prev-commits_prompt.md

          | Field     | Value |
          | :-------- | :---------------------------- |
          | role | consolidator |
          | query | check-prev-commits |
          | harness | pi |
          | provider | zai |
          | model | glm-5.3 |
          | timestamp | 2026-09-03T19:23:57 |
          | consolidated_at | 2026-09-03T19:40:05+07:00 |
          | duration | 00:02:10 |

          ### Sources

          | Source | Duration | Input | Cached | Output | Cost |
          | :----- | -------: | ----: | -----: | -----: | ---: |
          | openai / gpt-x | 00:01:05 | - | - | - | - |
        HEADER
        expect(File.read(File.join(dir, 'prefix_consolidated_pi_zai_glm-5.3.md'))).to eq('consolidated body')
        expect(Dir.exist?(File.join(dir, 'consolidated'))).to be(false)
      end
    end
  end

  describe '.consolidated_split' do
    def split_text(text) = described_class.consolidated_split(text).first

    it 'splits the findings from the meta part at the marker line' do
      findings, meta = split_text(
        "## Findings\n\n1. x\n\n=== META ===\n\n## Agent Consultants\n\n- #1 a / b\n")
      expect(findings).to eq("## Findings\n\n1. x\n\n")
      expect(meta).to eq("\n## Agent Consultants\n\n- #1 a / b\n")
    end

    it 'tolerates trailing whitespace on the marker line' do
      expect(split_text("f\n=== META ===  \n## Agent Consultants\n"))
        .to eq(["f\n", "## Agent Consultants\n"])
    end

    it 'accepts a CRLF line ending on the marker line' do
      expect(split_text("f\r\n=== META ===\r\n## Agent Consultants\r\n"))
        .to eq(["f\r\n", "## Agent Consultants\r\n"])
    end

    it 'does not take a marker quoted in the findings for the real one' do
      quoted = "f\n```\n=== META ===\n```\n\nmore findings\n"
      expect(split_text(quoted)).to be_nil
      # even when more findings headings follow the quoted marker
      expect(split_text("f\n=== META ===\n\n## Contradictions\n\nc\n")).to be_nil
      expect(split_text("#{quoted}\n=== META ===\n\n## Agent Consultants\n"))
        .to be_nil # twice, so ambiguous
    end

    it 'does not take a marker inside an unclosed code fence for the real one' do
      quoted = "## Findings\n\n```\n=== META ===\n\n## Agent Consultants\n\nquoted\n```\n"
      expect(split_text(quoted)).to be_nil
      tilde = "## Findings\n\n~~~\n=== META ===\n\n## Agent Consultants\n"
      expect(split_text(tilde)).to be_nil
      closed = "## Findings\n\n```\ncode\n```\n\n=== META ===\n\n## Agent Consultants\n"
      expect(split_text(closed)).not_to be_nil
    end

    it 'follows CommonMark fence rules: character and length must match to close' do
      nested = "## Findings\n\n````\n```\ncode\n```\n=== META ===\n\n## Agent Consultants\n"
      expect(split_text(nested)).to be_nil # still inside the four-backtick block
      closed = "## Findings\n\n````\n```\ncode\n```\n````\n\n=== META ===\n\n## Agent Consultants\n"
      expect(split_text(closed)).not_to be_nil # a valid block containing ```
      mixed = "## Findings\n\n```\n~~~\n\n=== META ===\n\n## Agent Consultants\n"
      expect(split_text(mixed)).to be_nil # ~~~ doesn't close ```
    end

    it 'returns nil unless the marker occurs once with text on both sides' do
      expect(split_text("## Findings\n\nf\n")).to be_nil
      expect(split_text("f\n=== META ===\n## m\n=== META ===\n## n\n")).to be_nil
      expect(split_text("=== META ===\n## m\n")).to be_nil
      expect(split_text("f\n=== META ===\nno heading\n")).to be_nil
      expect(split_text("f\n=== META ===\n  \n")).to be_nil
    end

    it 'treats a backtick line with backticks in its info string as no fence' do
      text = "## Findings\n\n```x`\n\n=== META ===\n\n## Agent Consultants\n"
      expect(split_text(text)).not_to be_nil
    end

    it 'closes fences by tilde, with an info string never, and with a longer fence' do
      meta = "\n=== META ===\n\n## Agent Consultants\n"
      expect(split_text("~~~\ncode\n~~~\n#{meta}")).not_to be_nil
      expect(split_text("```\ncode\n``` text\n#{meta}")).to be_nil
      expect(split_text("```\ncode\n`````\n#{meta}")).not_to be_nil
    end

    it 'says why it refuses' do
      expect(described_class.consolidated_split("f\n=== META ===\n## m\n=== META ===\n## n\n").last)
        .to include('more than one')
    end

    it 'ignores the marker inside a line' do
      expect(split_text("see === META === here\n")).to be_nil
    end
  end

  describe '.full_label' do
    it 'gives agent number, harness, provider, and model, defaulting the harness' do
      expect(described_class.full_label('agent_index' => 2, 'harness' => 'h', 'provider' => 'p',
        'model' => 'm'))
        .to eq('#2 h / p / m')
      expect(described_class.full_label('provider' => 'p', 'model' => 'm')).to eq('pi / p / m')
    end
  end

  describe '.split_consolidated_report' do
    let(:head) { "# Consolidated Report\n\n| t |\n" }
    let(:meta_name) { 'p_consolidated_pi_zai_glm_meta.md' }
    let(:findings_name) { 'p_consolidated_pi_zai_glm_findings.md' }
    let(:unsplit_name) { 'p_consolidated_pi_zai_glm.md' }
    let(:text) do
      "---\nrole: consolidator\n---\n\n#{head}\n## Findings\n\n1. f\n\n=== META ===\n\n" \
        "## Agent Consultants\n\nc\n"
    end

    def split(dir, head: self.head, info: [])
      consolidator = { 'provider' => 'zai', 'model' => 'glm' }
      labels = ['#1 pi / a / b']
      described_class.split_consolidated_report(dir, meta_name, 'p', consolidator, head, labels, info)
    end

    it "raises the error itself, not one from its fallback, when the entry can't name a file" do
      naming_error = Class.new(StandardError)
      allow(described_class).to receive(:consolidated_filename).and_raise(naming_error)
      Dir.mktmpdir do |dir|
        expect { described_class.split_consolidated_report(dir, 'x.md', 'p', {}, nil, []) }
          .to raise_error(naming_error)
      end
    end

    it 'writes the findings file and rewrites the report in place as the meta file' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, meta_name), text)

        result = split(dir, info: ['Run: p', 'Consolidated by: pi / zai / glm'])

        expect(result).to eq([findings_name, meta_name])
        expect(Dir.children(dir)).to contain_exactly(findings_name, meta_name)
        findings = File.read(File.join(dir, findings_name))
        expect(findings).to start_with(
          "# Consolidated Findings\n\n- Run: p\n- Consolidated by: pi / zai / glm\n\nAgents consulted")
        expect(findings).to include("- #1 pi / a / b\n", "## Findings\n\n1. f\n")
        expect(findings).not_to include('---', 'Agent Consultants', '=== META', 'Consolidated Report')
        meta = File.read(File.join(dir, meta_name))
        expect(meta).to eq("---\nrole: consolidator\n---\n\n#{head}\n## Agent Consultants\n\nc\n")
      end
    end

    it 'keeps the meta file taken, so the unsplit name is never the only guard' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, meta_name), text)
        split(dir)
        expect(File.exist?(File.join(dir, unsplit_name))).to be(false)
        expect { File.open(File.join(dir, meta_name), 'wx') }.to raise_error(Errno::EEXIST)
      end
    end

    it 'removes what it wrote and keeps the whole report when writing the meta file fails' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, meta_name), text)
        allow(File).to receive(:rename).and_call_original
        allow(File).to receive(:rename).with("#{File.join(dir, meta_name)}.tmp", File.join(dir, meta_name))
          .and_raise(Errno::ENOSPC)

        result = nil
        expect { result = split(dir) }.to output(/Could not split.*No space left/).to_stderr

        expect(result).to eq([unsplit_name, nil])
        expect(Dir.children(dir)).to eq([unsplit_name])
        expect(File.read(File.join(dir, unsplit_name))).to eq(text)
      end
    end

    it 'removes a partly written findings file, but not one it did not create' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, meta_name), text)
        allow(File).to receive(:open).and_call_original
        allow(File).to receive(:open).with(File.join(dir, findings_name), 'wx')
          .and_wrap_original do |original, path, mode, &block|
            original.call(path, mode) do |file|
              block.call(file)
              raise Errno::ENOSPC
            end
          end

        result = nil
        expect { result = split(dir) }.to output(/Could not split.*No space left/).to_stderr

        expect(result).to eq([unsplit_name, nil])
        expect(Dir.children(dir)).to eq([unsplit_name])
      end
    end

    it 'leaves the report and the file in its way alone when the findings file already exists' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, meta_name), text)
        File.write(File.join(dir, findings_name), 'stale')

        result = nil
        expect { result = split(dir) }.to output(/Could not split/).to_stderr

        expect(result).to eq([unsplit_name, nil])
        expect(File.read(File.join(dir, findings_name))).to eq('stale')
        expect(File.read(File.join(dir, unsplit_name))).to eq(text)
      end
    end

    it 'keeps the report when it cannot be decoded, rather than failing the consolidation' do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, meta_name), "#{head}\nbad \xFF\n=== META ===\n## Agent Consultants\n")
        result = nil
        expect { result = split(dir) }.to output(/Could not split/).to_stderr
        expect(result).to eq([unsplit_name, nil])
        expect(Dir.children(dir)).to eq([unsplit_name])
      end
    end

    it 'renames a report without the marker to the unsplit name, with a warning' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, meta_name), "---\na: b\n---\n\n#{head}\nno marker\n")
        result = nil
        expect { result = split(dir) }
          .to output(/Not splitting .*_meta\.md: it has no === META === line/).to_stderr
        expect(result).to eq([unsplit_name, nil])
        expect(Dir.children(dir)).to eq([unsplit_name])
      end
    end

    it 'keeps the report under its meta name, with a warning, if the unsplit name is taken' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, meta_name), "#{head}\nno marker\n")
        File.write(File.join(dir, unsplit_name), 'other')
        result = nil
        expect { result = split(dir) }.to output(/Not splitting.*\n.*exists; leaving the report as/).to_stderr
        expect(result).to eq([meta_name, nil])
        expect(File.read(File.join(dir, unsplit_name))).to eq('other')
      end
    end

    it 'keeps the report under its meta name, with a warning, if it cannot be renamed' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, meta_name), "#{head}\nno marker\n")
        allow(File).to receive(:rename).and_raise(Errno::EACCES)
        result = nil
        expect { result = split(dir) }.to output(/Could not rename .*Permission denied/).to_stderr
        expect(result).to eq([meta_name, nil])
      end
    end

    it 'says why a report is not split' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, meta_name),
          "#{head}\n## Findings\n\nf\n=== META ===\n\n## Contradictions\n\nc\n")
        expect { split(dir) }.to output(/not followed by an Agent Consultants section/).to_stderr
      end
    end

    it 'does not split a report whose header is not the one that was written' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, meta_name), text)
        result = nil
        expect { result = split(dir, head: 'other') }
          .to output(/Could not split .*header is not what was written/).to_stderr
        expect(result).to eq([unsplit_name, nil])
        expect(Dir.children(dir)).to eq([unsplit_name])
      end
    end

    it 'takes the whole body as the report when there is no header to skip' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, meta_name), "\n## Findings\n\nf\n=== META ===\n## Agent Consultants\n")
        expect(split(dir, head: nil)).to eq([findings_name, meta_name])
        expect(File.read(File.join(dir,
          findings_name))).to include('Agents consulted (agent number, harness, ' \
          "provider, model):\n\n- #1 pi / a / b\n\n\n## Findings")
      end
    end
  end

  describe 'the consolidation template' do
    it 'asks for the marker line the splitter looks for' do
      template = File.read(described_class::CONSOLIDATE_PROMPT_PATH, encoding: 'UTF-8')
      expect(template.lines.map(&:chomp)).to include(described_class::CONSOLIDATED_META_MARKER)
      # directly followed by the section the splitter requires to open the meta part
      marker = Regexp.escape(described_class::CONSOLIDATED_META_MARKER)
      expect(template).to match(/^#{marker}\n\n## Agent Consultants$/)
    end
  end

  describe '.compose_analyst_prompt' do
    it 'appends the format addendum to the prompt verbatim, separated by a blank line' do
      expect(described_class.compose_analyst_prompt("Analyze this.\n", 'FORMAT RULES'))
        .to eq("Analyze this.\n\nFORMAT RULES")
    end
  end

  describe '.consolidation_prompt' do
    it 'assembles the template, the original prompt, and labeled reports' do
      reports = [['openai-codex / gpt-5.4', 'findings A'], ['zai / glm-5.3', 'findings B']]
      text = described_class.consolidation_prompt('THE QUESTION', reports)
      expect(text).to include('THE QUESTION')
      expect(text).to include('## Report from openai-codex / gpt-5.4', 'findings A')
      expect(text).to include('## Report from zai / glm-5.3', 'findings B')
      expect(text).to match(/consolidat/i) # the instructions template
    end

    it "states each report's harness, defaulting to the current one" do
      reports = [['#1 zai / glm-5.3', 'findings A', { 'harness' => 'other' }],
        ['#2 openai / gpt-x', 'findings B', {}]]
      text = described_class.consolidation_prompt('THE QUESTION', reports)
      expect(text).to include("## Report from #1 zai / glm-5.3\n\nHarness: other\n\nfindings A")
      expect(text).to include("## Report from #2 openai / gpt-x\n\nHarness: pi\n\nfindings B")
    end

    it 'lists failed agents, with their reasons, after the reports' do
      reports = [['#1 zai / glm-5.3', 'findings A']]
      failures = [['#2 openai / gpt-x', "pi exited 1: rate\nlimited", 'pi']]
      text = described_class.consolidation_prompt('THE QUESTION', reports, failures)
      expect(text).to end_with(
        "# Agents without a report\n\n- #2 openai / gpt-x (harness: pi): pi exited 1: rate limited\n"
      )
    end

    it 'says none failed when there are no failures' do
      text = described_class.consolidation_prompt('THE QUESTION', [['#1 zai / glm-5.3', 'findings A']])
      expect(text).to end_with("# Agents without a report\n\nNone.\n")
    end
  end

  describe '.agent_descriptor' do
    it "names the entry's harness, provider, and model" do
      expect(described_class.agent_descriptor({ 'provider' => 'p', 'model' => 'm' })).to eq('pi / p / m')
      expect(described_class.agent_descriptor({ 'harness' => 'other', 'provider' => 'p', 'model' => 'm' }))
        .to eq('other / p / m')
    end
  end

  describe 'the sample configs in examples/configs' do
    Dir[File.expand_path('../examples/configs/*.yml', __dir__)].each do |path|
      it "#{File.basename(path)} is a valid config" do
        config = YAML.safe_load_file(path)
        entries = config.fetch('agents') + [config['consolidator']].compact
        expect(entries.map { |entry| described_class.entry_error(entry) }).to all(be_nil)
      end
    end
  end

  describe '.entry_error' do
    let(:entry) { { 'harness' => 'pi', 'provider' => 'p', 'model' => 'm' } }

    it 'accepts an entry giving a known harness, a provider, and a model' do
      expect(described_class.entry_error(entry)).to be_nil
      expect(described_class.entry_error(entry.merge('harness' => 'claude', 'extra' => 1))).to be_nil
    end

    it 'names every missing or blank key at once' do
      expect(described_class.entry_error({ 'model' => 'm', 'provider' => ' ' })).to eq(
        "is missing 'harness'; gives a blank 'provider'"
      )
      expect(described_class.entry_error({ 'harness' => 'pi', 'model' => '' })).to eq(
        "is missing 'provider'; gives a blank 'model'"
      )
      expect(described_class.entry_error({ 'harness' => ' ', 'provider' => '', 'model' => 'm' })).to eq(
        "gives blank values for 'harness' and 'provider'"
      )
      expect(described_class.entry_error({})).to eq("is missing 'harness', 'provider', and 'model'")
    end

    it 'says what a non-mapping entry is' do
      expect(described_class.entry_error(nil)).to end_with(', but is null')
      expect(described_class.entry_error('oops')).to end_with(', but is a string')
      expect(described_class.entry_error([entry])).to eq(
        "must be a mapping giving 'harness', 'provider', and 'model' (harness: pi, claude), but is a list"
      )
    end

    it 'names a value that is not a string, and its kind' do
      expect(described_class.entry_error(entry.merge('model' => 2026, 'harness' => false))).to eq(
        "gives 'harness' as a boolean, false, not a string (known: pi, claude); " \
        "gives 'model' as a number, 2026, not a string (quote it)"
      )
    end

    it "doesn't suggest quoting a list or mapping" do
      expect(described_class.entry_error(entry.merge('provider' => ['p'], 'model' => { 'm' => 1 }))).to eq(
        "gives 'provider' as a list, [\"p\"], not a string; " \
        "gives 'model' as a mapping, {\"m\" => 1}, not a string"
      )
    end

    it 'reports an unknown harness along with the other problems' do
      expect(described_class.entry_error({ 'harness' => 'nope', 'model' => 'm' })).to eq(
        "is missing 'provider'; names an unknown harness, \"nope\" (known: pi, claude)"
      )
    end

    # c60b7f8 let a Claude Code entry omit its provider; now none may.
    it 'requires a provider of a Claude Code entry too' do
      expect(described_class.entry_error({ 'harness' => 'claude', 'model' => 'm' }))
        .to eq("is missing 'provider'")
    end
  end

  describe '.missing_agents' do
    it "skips an entry it can't label" do
      config = { 'agents' => [{ 'harness' => 'claude', 'model' => 'claude-opus-5-5' }, 'junk'] }
      expect(described_class.missing_agents(config, [])).to eq([])
    end

    it 'lists configured agents without a report, labeled as reports are' do
      zai = { 'provider' => 'zai', 'model' => 'glm-5.3' }
      config = { 'agents' => [zai, zai, { 'provider' => 'openai', 'model' => 'gpt-x' }] }
      reports = [['#2 zai / glm-5.3', 'body', {}]]
      expect(described_class.missing_agents(config, reports).map(&:first))
        .to eq(['#1 zai / glm-5.3', '#3 openai / gpt-x'])
      expect(described_class.missing_agents(config, reports).first[1]).to include('reason not recorded')
    end

    it "gives an agent's harness, and the error and warnings run.json records for its failure" do
      claude = { 'harness' => 'claude', 'provider' => 'anthropic', 'model' => 'm' }
      config = { 'agents' => [{ 'provider' => 'zai', 'model' => 'glm-5.3' }, claude] }
      runs = [{ 'agent_index' => 2, 'harness' => 'claude', 'provider' => 'anthropic', 'model' => 'm',
                'ok' => false, 'error' => 'claude exited 1: out of turns', 'warnings' => ['refused make'] }]
      expect(described_class.missing_agents(config, [], runs)).to eq(
        [['#1 zai / glm-5.3', described_class::MISSING_REPORT_REASON, 'pi'],
          ['#2 anthropic / m', 'claude exited 1: out of turns; warning: refused make', 'claude']]
      )
    end

    it "ignores a run.json entry that isn't the configured agent's failure" do
      config = { 'agents' => [{ 'provider' => 'zai', 'model' => 'glm-5.3' }] }
      run = { 'agent_index' => 1, 'provider' => 'zai', 'model' => 'glm-5.3', 'ok' => false,
              'error' => 'boom' }
      entries = [run.merge('model' => 'other'), run.merge('ok' => true), run.merge('harness' => 'claude'),
        run.merge('error' => nil), 'junk']
      entries.each do |entry|
        expect(described_class.missing_agents(config, [], [entry]).first[1])
          .to eq(described_class::MISSING_REPORT_REASON)
      end
    end

    it 'is empty when every configured agent has a report' do
      config = { 'agents' => [{ 'provider' => 'zai', 'model' => 'glm-5.3' }] }
      expect(described_class.missing_agents(config, [['#1 zai / glm-5.3', 'body', {}]])).to eq([])
    end

    it 'is empty when the config copy lists no agents' do
      expect(described_class.missing_agents({}, [])).to eq([])
    end

    it 'lists an agent whose harness is unknown, since labeling it needs no harness' do
      config = { 'agents' => [{ 'harness' => 'nope', 'provider' => 'zai', 'model' => 'glm-5.3' }] }
      expect(described_class.missing_agents(config, []).map(&:first)).to eq(['#1 zai / glm-5.3'])
    end
  end
end
