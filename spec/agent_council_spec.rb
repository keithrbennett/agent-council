# frozen_string_literal: true

# Focused tests for the harness-agnostic logic in lib/agent_council.rb
# (no model calls). Pi-specific behavior is tested in
# spec/agent_council/pi_spec.rb. Run with: rspec

require 'tmpdir'
require_relative '../lib/agent_council'

RSpec.describe AgentCouncil do
  describe '.sanitize' do
    it 'keeps safe characters' do
      expect(AgentCouncil.sanitize('claude-sonnet-4-5')).to eq('claude-sonnet-4-5')
      expect(AgentCouncil.sanitize('kimi-k2.6')).to eq('kimi-k2.6')
      expect(AgentCouncil.sanitize('gpt-5.4')).to eq('gpt-5.4')
    end

    it 'replaces unsafe characters' do
      expect(AgentCouncil.sanitize('a/b')).to eq('a-b')
      expect(AgentCouncil.sanitize("a b\tc")).to eq('a-b-c')
      expect(AgentCouncil.sanitize('(x)')).to eq('x')
      expect(AgentCouncil.sanitize('.x.y.')).to eq('x.y')
    end

    it 'collapses runs of unsafe characters into one dash' do
      expect(AgentCouncil.sanitize('a//b::c')).to eq('a-b-c')
    end
  end

  describe '.query_slug' do
    [
      ['-', 'prompts/code-base-state-prompt.md', 'code-base-state'],
      ['_', 'prompts/code-base-state_prompt.md', 'code-base-state']
    ].each do |separator, path, expected_slug|
      it "strips the #{separator}prompt suffix" do
        expect(AgentCouncil.query_slug(path)).to eq(expected_slug)
      end
    end

    it 'strips the suffix case-insensitively' do
      expect(AgentCouncil.query_slug('/tmp/Security-Review_Prompt.md')).to eq('security-review')
      expect(AgentCouncil.query_slug('/tmp/Security-Review-PROMPT.md')).to eq('security-review')
    end

    it 'strips only a trailing suffix' do
      expect(AgentCouncil.query_slug('prompt-tuning.md')).to eq('prompt-tuning')
      expect(AgentCouncil.query_slug('my-prompts.md')).to eq('my-prompts')
      expect(AgentCouncil.query_slug('a-prompt-prompt.md')).to eq('a-prompt')
    end

    it 'works for prompt files not following the convention' do
      expect(AgentCouncil.query_slug('notes.md')).to eq('notes')
      expect(AgentCouncil.query_slug('prompt')).to eq('prompt') # no extension
    end

    it "falls back to 'prompt' when nothing usable remains" do
      expect(AgentCouncil.query_slug('!!!.md')).to eq('prompt')
      expect(AgentCouncil.query_slug('_prompt.md')).to eq('prompt')
      expect(AgentCouncil.query_slug('-prompt.md')).to eq('prompt')
    end
  end

  describe '.reports_dir' do
    around do |example|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    end

    it 'is ./reports under the current working directory (the analyzed repo)' do
      expect(AgentCouncil.reports_dir).to eq(File.join(Dir.pwd, 'reports'))
    end

    it 'is ./untracked/reports when the working directory has an untracked/ directory' do
      Dir.mkdir('untracked')
      expect(AgentCouncil.reports_dir).to eq(File.join(Dir.pwd, 'untracked', 'reports'))
    end

    it 'ignores a plain file named untracked' do
      File.write('untracked', '')
      expect(AgentCouncil.reports_dir).to eq(File.join(Dir.pwd, 'reports'))
    end
  end

  describe '.report_filename' do
    it 'carries the full timestamp and query slug, then harness/provider/model' do
      expect(AgentCouncil.report_filename('2026-09-03-19-23-57_code-base-state', 'opencode-go', 'kimi-k2.6'))
        .to eq('2026-09-03-19-23-57_code-base-state_pi_opencode-go_kimi-k2.6.md')
      expect(AgentCouncil.report_filename('2026-09-03-19-23-57_prompt', 'zai', 'glm-5.3'))
        .to eq('2026-09-03-19-23-57_prompt_pi_zai_glm-5.3.md')
    end
  end

  describe '.collect_reports' do
    it 'labels reports from front matter, sorted, bodies front-matter-free' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'a_pi_openai-codex_gpt-5.4.md'),
                   "---\nprovider: openai-codex\nmodel: gpt-5.4\n---\n\nbody B")
        File.write(File.join(dir, 'b_pi_zai_glm-5.3.md'),
                   "---\nprovider: zai\nmodel: glm-5.3\n---\n\nbody A")

        reports = AgentCouncil.collect_reports(dir)
        expect(reports).to eq([['openai-codex / gpt-5.4', 'body B'], ['zai / glm-5.3', 'body A']])
      end
    end

    it 'skips files without parseable front matter (not our reports)' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'notes.md'), 'just markdown')
        expect(AgentCouncil.collect_reports(dir)).to eq([])
      end
    end

    it 'skips files whose front matter is malformed' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'a.md'), "---\nprovider: [oops\n---\n\nbody")
        expect(AgentCouncil.collect_reports(dir)).to eq([])
      end
    end
  end

  describe 'front matter' do
    it 'with_front_matter and parse_front_matter round-trip' do
      content = AgentCouncil.with_front_matter({ 'provider' => 'zai', 'model' => 'glm-5.3' }, "# Report\n\nText.")
      fields, body = AgentCouncil.parse_front_matter(content)
      expect(fields).to eq('provider' => 'zai', 'model' => 'glm-5.3')
      expect(body).to eq("# Report\n\nText.\n")
    end

    it 'round-trips list values (e.g. consolidated sources) as YAML lists' do
      content = AgentCouncil.with_front_matter({ 'sources' => ['a / one', 'b / two'] }, 'body')
      fields, = AgentCouncil.parse_front_matter(content)
      expect(fields['sources']).to eq(['a / one', 'b / two'])
    end

    it 'parses unquoted ISO timestamps safely as UTC Time objects' do
      content = AgentCouncil.with_front_matter({ 'timestamp' => '2026-09-04T20:54:39' }, 'body')
      fields, = AgentCouncil.parse_front_matter(content)
      expect(fields['timestamp']).to be_a(Time)
      expect(fields['timestamp'].utc).to eq(Time.utc(2026, 9, 4, 20, 54, 39))
    end

    it 'returns no fields for plain markdown' do
      fields, = AgentCouncil.parse_front_matter("# Just markdown\n")
      expect(fields).to be_nil
    end
  end

  describe '.relative_path' do
    it 'returns paths relative to the current working directory when possible' do
      expect(AgentCouncil.relative_path(File.join(Dir.pwd, 'reports', 'x'))).to eq('reports/x')
    end
  end

  describe '.consolidated_filename' do
    it 'is distinct from agent report filenames and self-identifying' do
      name = AgentCouncil.consolidated_filename('2026-09-03-19-23-57_review', 'zai', 'glm-5.3')
      expect(name).to eq('2026-09-03-19-23-57_review_consolidated_pi_zai_glm-5.3.md')
      # distinct from analyst filenames; the "_consolidated" infix marks its role
    end
  end

  describe '.run_consolidation' do
    it 'fails cleanly when the config entry is malformed' do
      expect(AgentCouncil.run_consolidation({ 'provider' => 'zai' }, 'prompt', '/tmp/x', 'prefix'))
        .to eq(['consolidator', false, "config entry needs 'provider' and 'model'"])
    end

    it 'fails cleanly when there are no reports to consolidate' do
      Dir.mktmpdir do |dir|
        result = AgentCouncil.run_consolidation({ 'provider' => 'zai', 'model' => 'glm-5.3' }, 'prompt', dir, 'prefix')
        expect(result[0]).to eq('zai / glm-5.3 (consolidator)')
        expect(result[1]).to be(false)
        expect(result[2]).to match(/no reports found/)
      end
    end

    it 'writes the consolidated report at the top level of the run dir' do
      Dir.mktmpdir do |dir|
        answers = File.join(dir, 'answers')
        FileUtils.mkdir_p(answers)
        File.write(File.join(answers, 'analyst.md'),
                   AgentCouncil.with_front_matter({ 'provider' => 'openai', 'model' => 'gpt-x' }, 'findings'))

        captured = nil
        allow(AgentCouncil).to receive(:run_agent) do |_agent, _prompt, run_dir, _prefix, filename:, meta:, title: nil|
          captured = { run_dir: run_dir, filename: filename, meta: meta, title: title }
          File.write(File.join(run_dir, filename), 'consolidated body')
          ['zai / glm-5.3', true, filename]
        end

        label, ok, = AgentCouncil.run_consolidation({ 'provider' => 'zai', 'model' => 'glm-5.3' }, 'prompt', dir,
                                                    'prefix', meta: { 'timestamp' => '2026-09-03T19:23:57' })
        expect(ok).to be(true)
        expect(label).to eq('zai / glm-5.3 (consolidator)')
        expect(captured[:run_dir]).to eq(dir)
        expect(captured[:filename]).to eq('prefix_consolidated_pi_zai_glm-5.3.md')
        expect(captured[:meta]['role']).to eq('consolidator')
        expect(captured[:title]).to eq('Consolidated Report -- pi/zai/glm-5.3 -- 2026-09-03T19:23:57')
        expect(File.read(File.join(dir, captured[:filename]))).to eq('consolidated body')
        expect(Dir.exist?(File.join(dir, 'consolidated'))).to be(false)
      end
    end
  end

  describe '.consolidation_prompt' do
    it 'assembles the template, the original prompt, and labeled reports' do
      reports = [['openai-codex / gpt-5.4', 'findings A'], ['zai / glm-5.3', 'findings B']]
      text = AgentCouncil.consolidation_prompt('THE QUESTION', reports)
      expect(text).to include('THE QUESTION')
      expect(text).to include('## Report from openai-codex / gpt-5.4', 'findings A')
      expect(text).to include('## Report from zai / glm-5.3', 'findings B')
      expect(text).to match(/consolidat/i) # the instructions template
    end
  end
end
