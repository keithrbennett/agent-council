# frozen_string_literal: true

# Focused tests for the harness-agnostic logic in lib/agent_council.rb
# (no model calls). Pi-specific behavior is tested in
# spec/agent_council/pi_harness_spec.rb. Run with: rspec

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
    let(:agent) { { 'provider' => 'p', 'model' => 'm' } }
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

    it 'deletes the scratch dir after a successful run' do
      stub_capture3('', instance_double(Process::Status, success?: true))
      allow(described_class::HARNESS).to receive_messages(error_message: nil, final_response: 'answer')

      _label, ok, = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')

      expect(ok).to be(true)
      expect(scratch_dirs.size).to eq(1)
      expect(File).not_to exist(scratch_dirs.first)
    end

    it 'records the duration in the front matter, as an HH:MM:SS string' do
      stub_capture3('', instance_double(Process::Status, success?: true))
      allow(described_class::HARNESS).to receive_messages(error_message: nil, final_response: 'answer')

      _label, ok, filename = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')

      expect(ok).to be(true)
      fields, = described_class.parse_front_matter(File.read(File.join(run_dir, filename)))
      expect(fields['duration']).to match(/\A\d\d:\d\d:\d\d\z/)
    end

    it 'fails rather than replace an existing report' do
      stub_capture3('', instance_double(Process::Status, success?: true))
      allow(described_class::HARNESS).to receive_messages(error_message: nil, final_response: 'answer')
      File.write(File.join(run_dir, 'taken.md'), 'earlier')

      _label, ok, detail = described_class.run_agent(agent, 'prompt', run_dir, 'prefix', filename: 'taken.md')

      expect(ok).to be(false)
      expect(detail).to start_with('Errno::EEXIST')
      expect(File.read(File.join(run_dir, 'taken.md'))).to eq('earlier')
    end

    it 'deletes the scratch dir after a failed run' do
      stub_capture3('', instance_double(Process::Status, success?: false, exitstatus: 1))

      _label, ok, detail = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')

      expect(ok).to be(false)
      expect(detail).to include('exited 1: boom')
      expect(File).not_to exist(scratch_dirs.first)
    end

    it 'reads harness output as UTF-8 under a non-UTF-8 locale, without a pool' do
      message = { role: 'assistant', content: [{ type: 'text', text: 'Résumé ✓' }] }
      event = { type: 'message_end', message: message }
      allow(described_class::HARNESS).to receive(:argv)
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
      allow(described_class::HARNESS).to receive(:argv)
        .and_return(['sh', '-c', "printf '%s\\n' #{Shellwords.escape(JSON.generate(event))}"])

      _label, ok, detail = described_class.run_agent(agent, 'prompt', run_dir, 'prefix')

      expect(ok).to be(false)
      expect(detail).to include('the run failed', 'length')
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
      allow(described_class::HARNESS).to receive_messages(error_message: nil, final_response: 'answer')

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
      File.write('config.yml', YAML.dump('agents' => [{ 'provider' => 'p', 'model' => 'm' }]))
      ENV[described_class::ENV_OPTS_VAR] = '--output-dir from-env'
      allow(described_class).to receive(:abort_unless_harness_installed)
      allow(described_class).to receive(:run_agent).and_return(['#1 p / m', true, 'report.md'])
      allow(described_class).to receive(:puts_consolidation_status)

      expect { described_class.main(['p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
        .and output.to_stdout

      expect(File).to exist(File.join('from-env', Dir.children('from-env').first))
    end

    it 'lets command-line options override AGENT_COUNCIL_OPTS defaults' do
      File.write('p_prompt.md', 'hi')
      File.write('config.yml', YAML.dump('agents' => [{ 'provider' => 'p', 'model' => 'm' }]))
      ENV[described_class::ENV_OPTS_VAR] = '--output-dir from-env'
      allow(described_class).to receive(:abort_unless_harness_installed)
      allow(described_class).to receive(:run_agent).and_return(['#1 p / m', true, 'report.md'])
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

    %w[-h -v].each do |flag|
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
      File.write('config.yml', YAML.dump('agents' => [{ 'provider' => 'p', 'model' => 'm' }]))
      allow(described_class).to receive(:abort_unless_harness_installed)
      allow(described_class).to receive(:claim_run_dir).and_raise(Errno::EACCES, 'out')
      expect { described_class.main(['-o', 'out', 'p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output("Cannot create a run dir under out: Permission denied - out\n").to_stderr
    end

    it 'aborts with a pointer to the packaged sample configs when no config exists' do
      File.write('p_prompt.md', 'hi')
      samples = File.join(described_class::EXAMPLES_DIR, 'configs')
      expect { described_class.main(['p_prompt.md']) }
        .to raise_error(SystemExit)
        .and output(/Sample configs: #{Regexp.escape(samples)}/).to_stderr
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
        File.write(config, YAML.dump('agents' => [{ 'provider' => 'p', 'model' => 'm' }]))
        expect { described_class.main([prompt, config]) }
          .to raise_error(SystemExit)
          .and output(/need different file names, since all three are copied into the run dir: #{names}, /)
          .to_stderr
        expect(File).not_to exist('agent-council-reports')
      end
    end

    it 'aborts before creating a run dir when the prompt is named like the reviews dir' do
      File.write('reviews', 'hi')
      File.write('c.yml', YAML.dump('agents' => [{ 'provider' => 'p', 'model' => 'm' }]))
      expect { described_class.main(['reviews', 'c.yml']) }
        .to raise_error(SystemExit)
        .and output(/The prompt can't be named reviews/).to_stderr
      expect(File).not_to exist('agent-council-reports')
    end

    it 'aborts before creating a run dir when the harness executable is not on PATH' do
      File.write('p_prompt.md', 'hi')
      File.write('config.yml', YAML.dump('agents' => [{ 'provider' => 'p', 'model' => 'm' }]))
      Dir.mkdir('empty-bin')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('PATH', '').and_return(File.expand_path('empty-bin'))
      expect { described_class.main(['p_prompt.md', 'config.yml']) }
        .to raise_error(SystemExit)
        .and output(/pi executable not found; is `pi` installed.*\n.*Prerequisites/).to_stderr
      expect(File).not_to exist('agent-council-reports')
    end
  end

  describe '.main --consolidate' do
    include_context 'with isolated cwd and home'

    let(:run_dir) { 'agent-council-reports/2026-09-03/09-14-02' }
    let(:consolidator_config) { { 'consolidator' => { 'provider' => 'c', 'model' => 'cm' } } }
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

    it 'aborts when the reports predate --consolidate (no prompt_file, config_file, run_stamp or query)' do
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

    it 'aborts when query is missing' do
      write_run(fields: analyst_fields.except('query'))
      expect_abort(/lack prompt_file, config_file, run_stamp or query/)
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
      write_run(config: { 'consolidator' => { 'provider' => 'c' } })
      expect_abort(/Consolidator in .*config\.yml needs string 'provider' and 'model' fields/)
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
      expect_abort(/Consolidated report already exists: #{Regexp.escape(existing)}\nDelete it/)
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
    it 'carries the full timestamp and query slug, then harness/provider/model' do
      expect(described_class.report_filename('2026-09-03-19-23-57_code-base-state', 'opencode-go',
        'kimi-k2.6'))
        .to eq('2026-09-03-19-23-57_code-base-state_pi_opencode-go_kimi-k2.6.md')
      expect(described_class.report_filename('2026-09-03-19-23-57_prompt', 'zai', 'glm-5.3'))
        .to eq('2026-09-03-19-23-57_prompt_pi_zai_glm-5.3.md')
    end

    it 'inserts a zero-padded agent index before the harness, disambiguating repeated provider/model pairs' do
      expect(described_class.report_filename('2026-09-03-19-23-57_prompt', 'zai', 'glm-5.3', index: 1))
        .to eq('2026-09-03-19-23-57_prompt_01_pi_zai_glm-5.3.md')
      expect(described_class.report_filename('2026-09-03-19-23-57_prompt', 'zai', 'glm-5.3', index: 2))
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
          "---\nprovider: zai\nmodel: glm-5.3\nduration: '00:01:05'\n---\n\nbody")
        _label, _body, fields = described_class.collect_reports(dir).first
        expect(fields).to eq('provider' => 'zai', 'model' => 'glm-5.3', 'duration' => '00:01:05')
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

    it 'round-trips #N source labels and a source_durations hash as valid YAML' do
      fields = {
        'sources'          => ['#1 zai / glm-5.3', '#2 zai / glm-5.3'],
        'source_durations' => { '#1 zai / glm-5.3' => '00:03:43', '#2 zai / glm-5.3' => '00:01:05' },
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

  describe '.format_result_table' do
    it 'aligns columns under headings, with the report on success and the error on failure' do
      results = [['claude/opus', true, 'a.md', 61], ['#2 openai/gpt-x', false, 'exit 1', 3]]
      expect(described_class.format_result_table(results)).to eq([
        '  Ok  Duration  Agent            Report',
        '  ✓   00:01:01  claude/opus      a.md',
        '  ✗   00:00:03  #2 openai/gpt-x  (exit 1)',
      ])
    end

    it 'aligns by display width, so wide characters take two columns' do
      results = [['模型', true, 'a.md', 1], ['abcd', true, 'b.md', 1]]
      expect(described_class.format_result_table(results).drop(1)).to eq([
        '  ✓   00:00:01  模型   a.md',
        '  ✓   00:00:01  abcd   b.md',
      ])
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
      name = described_class.consolidated_filename('2026-09-03-19-23-57_review', 'zai', 'glm-5.3')
      expect(name).to eq('2026-09-03-19-23-57_review_consolidated_pi_zai_glm-5.3.md')
      # distinct from analyst filenames; the "_consolidated" infix marks its role
    end
  end

  describe '.byline_table' do
    it 'lists the main front matter fields, one row per source' do
      meta = {
        'role'      => 'consolidator',
        'query'     => 'check-prev-commits',
        'timestamp' => '2026-09-03T19:23:57',
        'sources'   => ['openai / gpt-x', 'zai / glm-5.3'],
      }
      expect(described_class.byline_table(meta, 'zai', 'glm-5.3')).to eq(
        "| Field     | Value |\n" \
        "| :-------- | :---------------------------- |\n" \
        "| role | consolidator |\n" \
        "| query | check-prev-commits |\n" \
        "| harness | pi |\n" \
        "| provider | zai |\n" \
        "| model | glm-5.3 |\n" \
        "| timestamp | 2026-09-03T19:23:57 |\n" \
        "| source | openai / gpt-x |\n" \
        "| source | zai / glm-5.3 |\n"
      )
    end

    it 'adds a duration row and annotates sources with their durations' do
      meta = { 'role' => 'consolidator', 'duration' => '00:02:10', 'sources' => ['a / b'],
        'source_durations' => { 'a / b' => '00:00:42' } }
      table = described_class.byline_table(meta, 'openai', 'gpt-x')
      expect(table).to include('| duration | 00:02:10 |')
      expect(table).to include('| source | a / b (00:00:42) |')
    end

    it 'omits source rows when there are none (analyst reports)' do
      meta = { 'role' => 'analyst', 'query' => 'review', 'timestamp' => '2026-09-03T19:23:57' }
      table = described_class.byline_table(meta, 'openai', 'gpt-x')
      expect(table).not_to include('| source |')
      expect(table).to include('| role | analyst |')
      expect(table).to include('| model | gpt-x |')
    end

    it 'adds an agent row when an agent_index is present' do
      meta = { 'role' => 'analyst', 'query' => 'review', 'timestamp' => '2026-09-03T19:23:57',
        'agent_index' => 2 }
      table = described_class.byline_table(meta, 'openai', 'gpt-x')
      expect(table).to include('| agent | #2 |')
    end

    it 'omits the agent row when there is no agent_index (consolidator)' do
      meta = { 'role' => 'consolidator', 'query' => 'review', 'timestamp' => '2026-09-03T19:23:57' }
      table = described_class.byline_table(meta, 'openai', 'gpt-x')
      expect(table).not_to include('| agent |')
    end
  end

  describe '.run_consolidation' do
    it 'fails cleanly when the config entry is malformed' do
      expect(described_class.run_consolidation({ 'provider' => 'zai' }, 'prompt', '/tmp/x', 'prefix'))
        .to eq(['consolidator', false, "config entry needs 'provider' and 'model'"])
    end

    it 'fails cleanly when there are no reports to consolidate' do
      Dir.mktmpdir do |dir|
        result = described_class.run_consolidation({ 'provider' => 'zai', 'model' => 'glm-5.3' },
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

        result = described_class.run_consolidation({ 'provider' => 'zai', 'model' => 'glm-5.3' },
          'prompt', dir, 'prefix')
        expect(result).to eq(['zai / glm-5.3', false, 'ArgumentError: invalid byte sequence'])
      end
    end

    it 'writes the consolidated report at the top level of the run dir' do
      Dir.mktmpdir do |dir|
        reviews = File.join(dir, 'reviews')
        FileUtils.mkdir_p(reviews)
        File.write(File.join(reviews, 'analyst.md'),
          described_class.with_front_matter(
            { 'provider' => 'openai', 'model' => 'gpt-x', 'duration' => '00:01:05' }, 'findings'))

        allow(Time).to receive(:now).and_return(Time.new(2026, 9, 3, 19, 40, 5, '+07:00'))
        captured = nil
        allow(described_class).to receive(:run_agent) do |_agent, _prompt, run_dir, _prefix,
          filename:, meta:, header: nil, pool: nil|
          captured = { run_dir: run_dir, filename: filename, meta: meta, header: header }
          File.write(File.join(run_dir, filename), 'consolidated body')
          ['zai / glm-5.3', true, filename]
        end

        label, ok, = described_class.run_consolidation({ 'provider' => 'zai', 'model' => 'glm-5.3' },
          'prompt', dir, 'prefix', meta: {
            'query'     => 'check-prev-commits',
            'timestamp' => '2026-09-03T19:23:57',
          }, prompt_path: 'prompts/check-prev-commits_prompt.md')
        expect(ok).to be(true)
        expect(label).to eq('zai / glm-5.3')
        expect(captured[:run_dir]).to eq(dir)
        expect(captured[:filename]).to eq('prefix_consolidated_pi_zai_glm-5.3.md')
        expect(captured[:meta]['role']).to eq('consolidator')
        expect(captured[:meta]['consolidated_at']).to eq('2026-09-03T19:40:05+07:00')
        expect(captured[:header].call('00:02:10')).to eq(<<~HEADER)
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
          | source | openai / gpt-x (00:01:05) |
        HEADER
        expect(File.read(File.join(dir, captured[:filename]))).to eq('consolidated body')
        expect(Dir.exist?(File.join(dir, 'consolidated'))).to be(false)
      end
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

    it 'lists failed agents, with their reasons, after the reports' do
      reports = [['#1 zai / glm-5.3', 'findings A']]
      failures = [['#2 openai / gpt-x', 'pi exited 1: rate limited']]
      text = described_class.consolidation_prompt('THE QUESTION', reports, failures)
      expect(text).to end_with(
        "# Agents without a report\n\n- #2 openai / gpt-x: pi exited 1: rate limited\n"
      )
    end

    it 'says none failed when there are no failures' do
      text = described_class.consolidation_prompt('THE QUESTION', [['#1 zai / glm-5.3', 'findings A']])
      expect(text).to end_with("# Agents without a report\n\nNone.\n")
    end
  end

  describe '.missing_agents' do
    it 'lists configured agents without a report, labeled as reports are' do
      zai = { 'provider' => 'zai', 'model' => 'glm-5.3' }
      config = { 'agents' => [zai, zai, { 'provider' => 'openai', 'model' => 'gpt-x' }] }
      reports = [['#2 zai / glm-5.3', 'body', {}]]
      expect(described_class.missing_agents(config, reports).map(&:first))
        .to eq(['#1 zai / glm-5.3', '#3 openai / gpt-x'])
      expect(described_class.missing_agents(config, reports).first.last).to include('reason not recorded')
    end

    it 'is empty when every configured agent has a report' do
      config = { 'agents' => [{ 'provider' => 'zai', 'model' => 'glm-5.3' }] }
      expect(described_class.missing_agents(config, [['#1 zai / glm-5.3', 'body', {}]])).to eq([])
    end

    it 'is empty when the config copy lists no agents' do
      expect(described_class.missing_agents({}, [])).to eq([])
    end
  end
end
