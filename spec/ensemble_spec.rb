# frozen_string_literal: true

# Focused tests for the harness-agnostic logic in ensemble.rb (no model
# calls). Pi-specific behavior is tested in pi_harness_spec.rb.
# Run with: rspec

require_relative '../ensemble'

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

  describe '.report_filename' do
    it 'carries the full timestamp and query slug, then harness/provider/model' do
      expect(Ensemble.report_filename('2026-09-03-19-23-57_code-base-state', 'opencode-go', 'kimi-k2.6'))
        .to eq('2026-09-03-19-23-57_code-base-state_pi_opencode-go_kimi-k2.6.md')
      expect(Ensemble.report_filename('2026-09-03-19-23-57_prompt', 'zai', 'glm-5.3'))
        .to eq('2026-09-03-19-23-57_prompt_pi_zai_glm-5.3.md')
    end
  end
end
