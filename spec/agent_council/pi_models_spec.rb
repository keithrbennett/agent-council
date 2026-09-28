# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require_relative '../../lib/agent_council/pi_models'

RSpec.describe AgentCouncil::PiModels do
  let(:models) do
    [
      described_class::Model.new(
        provider:       'anthropic',
        id:             'claude-sonnet',
        name:           'Claude Sonnet',
        api:            'anthropic-messages',
        reasoning:      true,
        context_window: 200_000,
        max_tokens:     8_192
      ),
      described_class::Model.new(
        provider:       'openai',
        id:             'gpt-mini',
        name:           'GPT Mini',
        api:            'openai-responses',
        reasoning:      false,
        context_window: 128_000,
        max_tokens:     4_096
      ),
    ]
  end

  describe AgentCouncil::PiModels::Model do
    let(:raw_model) do
      {
        'provider'      => 'anthropic',
        'id'            => 'claude-sonnet',
        'name'          => 'Claude Sonnet',
        'api'           => 'anthropic-messages',
        'reasoning'     => true,
        'contextWindow' => 200_000,
        'maxTokens'     => 8_192,
      }
    end

    it 'deserializes pi field names into Ruby accessors' do
      model = described_class.from_hash(raw_model)

      expect(model.provider).to eq('anthropic')
      expect(model.context_window).to eq(200_000)
      expect(model.max_tokens).to eq(8_192)
    end

    it 'raises ArgumentError naming the missing fields' do
      raw = raw_model.except('id', 'maxTokens')

      expect { described_class.from_hash(raw) }
        .to raise_error(ArgumentError, 'missing model field(s): id, maxTokens')
    end

    it 'serializes using pi JSON field names' do
      expect(described_class.from_hash(raw_model).to_h).to eq(raw_model)
    end
  end

  describe '.event_to_models' do
    it 'parses models from a successful RPC response' do
      event = {
        'success' => true,
        'data'    => { 'models' => [
          {
            'provider' => 'anthropic', 'id' => 'claude-sonnet',
            'name' => 'Claude Sonnet', 'api' => 'anthropic-messages',
            'reasoning' => true, 'contextWindow' => 200_000, 'maxTokens' => 8_192
          },
        ] },
      }

      result = described_class.event_to_models(event)

      expect(result.map(&:id)).to eq(['claude-sonnet'])
      expect(result.first.context_window).to eq(200_000)
    end

    it 'raises the error from an unsuccessful RPC response' do
      expect { described_class.event_to_models('success' => false, 'error' => 'not configured') }
        .to raise_error(RuntimeError, 'pi error: not configured')
    end
  end

  describe '.format_as_json' do
    it 'pretty prints an array using pi field names and a final newline' do
      output = described_class.format_as_json(models.first(1))

      expect(JSON.parse(output)).to eq([models.first.to_h])
      expect(output).to include('"contextWindow": 200000', '"maxTokens": 8192')
      expect(output).to end_with("\n")
    end

    it 'formats an empty model list as an empty JSON array' do
      expect(described_class.format_as_json([])).to eq("[]\n")
    end
  end

  describe '.format_as_ids' do
    it 'writes provider/model pairs one per line' do
      expect(described_class.format_as_ids(models)).to eq("anthropic/claude-sonnet\nopenai/gpt-mini\n")
    end

    it 'returns a newline for an empty model list' do
      expect(described_class.format_as_ids([])).to eq("\n")
    end
  end

  describe '.format_as_table' do
    it 'formats headers, separators, aligned numeric columns, and model values' do
      expected = <<~TABLE
        ---------  -------------  ------------------  ---------  -------  ----------  -------------
        PROVIDER   MODEL ID       API                 REASONING  CONTEXT  MAX TOKENS  NAME
        ---------  -------------  ------------------  ---------  -------  ----------  -------------
        anthropic  claude-sonnet  anthropic-messages  yes         200000        8192  Claude Sonnet
        openai     gpt-mini       openai-responses    no          128000        4096  GPT Mini
        ---------  -------------  ------------------  ---------  -------  ----------  -------------
      TABLE

      expect(described_class.format_as_table(models)).to eq(expected)
    end

    it 'shows setup guidance when there are no models' do
      expect(described_class.format_as_table([]))
        .to eq("No models configured. Run `pi` interactively and add a provider first.\n")
    end
  end

  describe '.help_text' do
    it 'documents the output options and examples' do
      expect(described_class.help_text).to include(
        'Usage: pi-models [options]',
        '--table', '--json', '--ids', '--help',
        'pi-models --json | jq'
      )
    end
  end

  describe 'the pi-models executable' do
    it 'prints help and exits without invoking pi' do
      executable = File.expand_path('../../exe/pi-models', __dir__)
      out, err, status = Open3.capture3(RbConfig.ruby, executable, '--help')

      expect(status).to be_success, err
      expect(out).to eq(described_class.help_text)
      expect(err).to be_empty
    end
  end
end
