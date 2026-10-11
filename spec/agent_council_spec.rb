# frozen_string_literal: true

# Focused tests for the harness-agnostic logic in lib/agent_council.rb
# (no model calls). Pi-specific behavior is tested in
# spec/agent_council/pi_harness_spec.rb. Run with: rspec

require 'spec_helper'
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

    it 'is ./reports under the current working directory (the analyzed repo)' do
      expect(described_class.reports_dir).to eq(File.join(Dir.pwd, 'reports'))
    end

    it 'is ./untracked/reports when the working directory has an untracked/ directory' do
      Dir.mkdir('untracked')
      expect(described_class.reports_dir).to eq(File.join(Dir.pwd, 'untracked', 'reports'))
    end

    it 'ignores a plain file named untracked' do
      File.write('untracked', '')
      expect(described_class.reports_dir).to eq(File.join(Dir.pwd, 'reports'))
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

    # Stub Dir.home rather than mutating ENV['HOME']: Dir.home's env-var
    # precedence differs by platform (e.g. USERPROFILE on Windows).
    before { allow(Dir).to receive(:home).and_return(home) }
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

  describe '.main' do
    include_context 'with isolated cwd and home'

    it 'aborts with a pointer to the packaged sample configs when no config exists' do
      File.write('p_prompt.md', 'hi')
      samples = File.join(described_class::EXAMPLES_DIR, 'configs')
      expect { described_class.main(['p_prompt.md']) }
        .to raise_error(SystemExit)
        .and output(/Sample configs: #{Regexp.escape(samples)}/).to_stderr
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

  describe '.collect_reports' do
    it 'labels reports from front matter, sorted, bodies front-matter-free' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'a_pi_openai-codex_gpt-5.4.md'),
          "---\nprovider: openai-codex\nmodel: gpt-5.4\n---\n\nbody B")
        File.write(File.join(dir, 'b_pi_zai_glm-5.3.md'),
          "---\nprovider: zai\nmodel: glm-5.3\n---\n\nbody A")

        reports = described_class.collect_reports(dir)
        expect(reports).to eq([['openai-codex / gpt-5.4', 'body B'], ['zai / glm-5.3', 'body A']])
      end
    end

    it 'skips files without parseable front matter (not our reports)' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'notes.md'), 'just markdown')
        expect(described_class.collect_reports(dir)).to eq([])
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

        reports = described_class.collect_reports(dir)
        expect(reports).to eq([['#1 zai / glm-5.3', 'body A'], ['#2 zai / glm-5.3', 'body B']])
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

  describe '.format_result_line' do
    it 'shows the report path after an arrow on success' do
      expect(described_class.format_result_line('claude/opus', true, 'answers/a.md', 61))
        .to eq('  ✓ 00:01:01  claude/opus  ->  answers/a.md')
    end

    it 'shows the error in parentheses on failure' do
      expect(described_class.format_result_line('claude/opus', false, 'exit 1', 3))
        .to eq('  ✗ 00:00:03  claude/opus  (exit 1)')
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
    it 'mirrors the front matter fields, centered, one row per source' do
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
        expect(result[0]).to eq('zai / glm-5.3 (consolidator)')
        expect(result[1]).to be(false)
        expect(result[2]).to include('no reports found')
      end
    end

    it 'writes the consolidated report at the top level of the run dir' do
      Dir.mktmpdir do |dir|
        answers = File.join(dir, 'answers')
        FileUtils.mkdir_p(answers)
        File.write(File.join(answers, 'analyst.md'),
          described_class.with_front_matter({ 'provider' => 'openai', 'model' => 'gpt-x' }, 'findings'))

        captured = nil
        allow(described_class).to receive(:run_agent) do |_agent, _prompt, run_dir, _prefix,
          filename:, meta:, header: nil|
          captured = { run_dir: run_dir, filename: filename, meta: meta, header: header }
          File.write(File.join(run_dir, filename), 'consolidated body')
          ['zai / glm-5.3', true, filename]
        end

        label, ok, = described_class.run_consolidation({ 'provider' => 'zai', 'model' => 'glm-5.3' },
          'prompt', dir, 'prefix', source_durations: { 'openai / gpt-x' => '00:01:05' }, meta: {
            'query'     => 'check-prev-commits',
            'timestamp' => '2026-09-03T19:23:57',
          }, prompt_path: 'prompts/check-prev-commits_prompt.md')
        expect(ok).to be(true)
        expect(label).to eq('zai / glm-5.3 (consolidator)')
        expect(captured[:run_dir]).to eq(dir)
        expect(captured[:filename]).to eq('prefix_consolidated_pi_zai_glm-5.3.md')
        expect(captured[:meta]['role']).to eq('consolidator')
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
  end
end
