# frozen_string_literal: true

# Focused tests for the harness-agnostic logic in ensemble.rb (no model
# calls). Pi-specific behavior is tested in pi_harness_spec.rb.
# Run with: rspec

require_relative '../lib/ensemble'

RSpec.describe Ensemble do
  describe '.sanitize' do
    it 'keeps safe characters' do
      expect(Ensemble.sanitize('claude-sonnet-4-5')).to eq('claude-sonnet-4-5')
      expect(Ensemble.sanitize('kimi-k2.6')).to eq('kimi-k2.6')
      expect(Ensemble.sanitize('gpt-5.4')).to eq('gpt-5.4')
    end

    it 'replaces unsafe characters' do
      expect(Ensemble.sanitize('a/b')).to eq('a-b')
      expect(Ensemble.sanitize("a b\tc")).to eq('a-b-c')
      expect(Ensemble.sanitize('(x)')).to eq('x')
      expect(Ensemble.sanitize('.x.y.')).to eq('x.y')
    end

    it 'collapses runs of unsafe characters into one dash' do
      expect(Ensemble.sanitize('a//b::c')).to eq('a-b-c')
    end
  end

  describe '.query_slug' do
    it 'comes from the prompt filename, stripping the conventional _prompt suffix' do
      expect(Ensemble.query_slug('prompts/code-base-state_prompt.md')).to eq('code-base-state')
      expect(Ensemble.query_slug('/tmp/Security-Review_Prompt.md')).to eq('security-review')
    end

    it 'works for prompt files not following the convention' do
      expect(Ensemble.query_slug('notes.md')).to eq('notes')
      expect(Ensemble.query_slug('prompt')).to eq('prompt') # no extension
    end

    it "falls back to 'prompt' when nothing usable remains" do
      expect(Ensemble.query_slug('!!!.md')).to eq('prompt')
      expect(Ensemble.query_slug('_prompt.md')).to eq('prompt')
    end
  end

  describe '.reports_dir' do
    it 'is ./reports under the current working directory (the analyzed repo)' do
      expect(Ensemble.reports_dir).to eq(File.join(Dir.pwd, 'reports'))
    end
  end

  describe '.report_filename' do
    it 'carries the full timestamp and query slug, then harness/provider/model' do
      expect(Ensemble.report_filename('2026-09-03-19-23-57_code-base-state', 'opencode-go', 'kimi-k2.6'))
        .to eq('2026-09-03-19-23-57_code-base-state_pi_opencode-go_kimi-k2.6.md')
      expect(Ensemble.report_filename('2026-09-03-19-23-57_prompt', 'zai', 'glm-5.3'))
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

        reports = Ensemble.collect_reports(dir)
        expect(reports).to eq([['openai-codex / gpt-5.4', 'body B'], ['zai / glm-5.3', 'body A']])
      end
    end

    it 'skips files without parseable front matter (not our reports)' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'notes.md'), 'just markdown')
        expect(Ensemble.collect_reports(dir)).to eq([])
      end
    end

    it 'skips files whose front matter is malformed' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'a.md'), "---\nprovider: [oops\n---\n\nbody")
        expect(Ensemble.collect_reports(dir)).to eq([])
      end
    end
  end

  describe 'front matter' do
    it 'with_front_matter and parse_front_matter round-trip' do
      content = Ensemble.with_front_matter({ 'provider' => 'zai', 'model' => 'glm-5.3' }, "# Report\n\nText.")
      fields, body = Ensemble.parse_front_matter(content)
      expect(fields).to eq('provider' => 'zai', 'model' => 'glm-5.3')
      expect(body).to eq("# Report\n\nText.\n")
    end

    it 'round-trips list values (e.g. consolidated sources) as YAML lists' do
      content = Ensemble.with_front_matter({ 'sources' => ['a / one', 'b / two'] }, 'body')
      fields, = Ensemble.parse_front_matter(content)
      expect(fields['sources']).to eq(['a / one', 'b / two'])
    end

    it 'parses unquoted ISO timestamps safely as UTC Time objects' do
      content = Ensemble.with_front_matter({ 'timestamp' => '2026-09-04T20:54:39' }, 'body')
      fields, = Ensemble.parse_front_matter(content)
      expect(fields['timestamp']).to be_a(Time)
      expect(fields['timestamp'].utc).to eq(Time.utc(2026, 9, 4, 20, 54, 39))
    end

    it 'returns no fields for plain markdown' do
      fields, = Ensemble.parse_front_matter("# Just markdown\n")
      expect(fields).to be_nil
    end
  end

  describe '.relative_path' do
    it 'returns paths relative to the current working directory when possible' do
      expect(Ensemble.relative_path(File.join(Dir.pwd, 'reports', 'x'))).to eq('reports/x')
    end
  end

  describe '.consolidated_filename' do
    it 'is distinct from agent report filenames and self-identifying' do
      name = Ensemble.consolidated_filename('2026-09-03-19-23-57_review', 'zai', 'glm-5.3')
      expect(name).to eq('2026-09-03-19-23-57_review_consolidated_pi_zai_glm-5.3.md')
      # distinct from analyst filenames; also lives apart in consolidated/
    end
  end

  describe '.run_consolidation' do
    it 'fails cleanly when the config entry is malformed' do
      expect(Ensemble.run_consolidation({ 'provider' => 'zai' }, 'prompt', '/tmp/x', 'prefix'))
        .to eq(['consolidator', false, "config entry needs 'provider' and 'model'"])
    end

    it 'fails cleanly when there are no reports to consolidate' do
      Dir.mktmpdir do |dir|
        result = Ensemble.run_consolidation({ 'provider' => 'zai', 'model' => 'glm-5.3' }, 'prompt', dir, 'prefix')
        expect(result[0]).to eq('zai / glm-5.3 (consolidator)')
        expect(result[1]).to be(false)
        expect(result[2]).to match(/no reports found/)
      end
    end
  end

  describe '.consolidation_prompt' do
    it 'assembles the template, the original prompt, and labeled reports' do
      reports = [['openai-codex / gpt-5.4', 'findings A'], ['zai / glm-5.3', 'findings B']]
      text = Ensemble.consolidation_prompt('THE QUESTION', reports)
      expect(text).to include('THE QUESTION')
      expect(text).to include('## Report from openai-codex / gpt-5.4', 'findings A')
      expect(text).to include('## Report from zai / glm-5.3', 'findings B')
      expect(text).to match(/consolidat/i) # the instructions template
    end
  end
end
