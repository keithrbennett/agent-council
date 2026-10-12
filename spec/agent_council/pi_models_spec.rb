# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'shellwords'
require 'tmpdir'
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
        .to raise_error(described_class::Error, 'pi error: not configured')
    end

    it 'raises a PiModels::Error when data.models is absent' do
      expect { described_class.event_to_models('success' => true, 'data' => {}) }
        .to raise_error(described_class::Error, /pi response missing data\.models/)
    end

    it 'raises a PiModels::Error when data.models is not an array' do
      expect { described_class.event_to_models('success' => true, 'data' => { 'models' => 'oops' }) }
        .to raise_error(described_class::Error, /pi response missing data\.models/)
    end

    it 'raises a PiModels::Error when a model is missing fields' do
      event = {
        'success' => true,
        'data'    => { 'models' => [{ 'provider' => 'anthropic', 'id' => 'claude-sonnet' }] },
      }

      expect { described_class.event_to_models(event) }
        .to raise_error(described_class::Error, /pi returned a malformed model: missing model field/)
    end
  end

  describe '.fetch_models' do
    before do
      # The fake `pi` below is a #!/bin/sh script (and one variant sends
      # itself a POSIX signal), so it can't run on Windows.
      skip 'requires a POSIX shell to build the fake pi executable' if Gem.win_platform?
    end

    def with_fake_pi(script)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'pi')
        File.write(path, "#!/bin/sh\n#{script}\n")
        File.chmod(0o755, path)
        original_path = ENV.fetch('PATH')
        ENV['PATH'] = "#{dir}:#{original_path}"
        begin
          yield
        ensure
          ENV['PATH'] = original_path
        end
      end
    end

    let(:response_json) do
      JSON.generate(
        'type' => 'response', 'id' => 'list-models', 'success' => true,
        'data' => { 'models' => [{
          'provider' => 'anthropic', 'id' => 'claude-sonnet', 'name' => 'Claude Sonnet',
          'api' => 'anthropic-messages', 'reasoning' => true,
          'contextWindow' => 200_000, 'maxTokens' => 8_192
        }] }
      )
    end

    it 'ignores non-JSON and unrelated lines around the response' do
      script = "echo 'warming up...'; echo '{\"type\":\"event\"}'; echo ''; " \
               "echo #{Shellwords.escape(response_json)}"
      with_fake_pi(script) do
        expect(described_class.fetch_models.map(&:id)).to eq(['claude-sonnet'])
      end
    end

    it 'reads pi output as UTF-8 under a non-UTF-8 locale' do
      json = response_json.sub('Claude Sonnet', 'Clàude ✓')
      with_fake_pi("echo #{Shellwords.escape(json)}") do
        models = with_us_ascii_locale { described_class.fetch_models }
        expect(models.map(&:name)).to eq(['Clàude ✓'])
      end
    end

    it 'includes pi stderr when it exits without responding' do
      with_fake_pi("echo 'no credentials configured' >&2; exit 3") do
        expect { described_class.fetch_models }
          .to raise_error(described_class::Error, /pi exited \(3\).*no credentials configured/)
      end
    end

    it 'raises a clear error when pi is not installed' do
      original_path = ENV.fetch('PATH')
      ENV['PATH'] = ''
      begin
        expect { described_class.fetch_models }
          .to raise_error(described_class::Error, /pi executable not found/)
      ensure
        ENV['PATH'] = original_path
      end
    end

    it 'reports the exit status instead of crashing when pi exits before reading stdin' do
      with_fake_pi("echo 'boom' >&2; exit 9") do
        expect { described_class.fetch_models }
          .to raise_error(described_class::Error, /pi exited \(9\).*boom/m)
      end
    end

    it 'reports the signal instead of a blank status when pi is killed by a signal' do
      with_fake_pi('kill -TERM $$') do
        expect { described_class.fetch_models }
          .to raise_error(described_class::Error, /pi exited \(signal 15\) before responding/)
      end
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

    it 'renders nil values as empty cells instead of raising' do
      sparse = described_class::Model.new(
        provider: 'openai', id: 'gpt-mini', name: nil, api: nil,
        reasoning: false, context_window: nil, max_tokens: nil
      )

      expect { described_class.format_as_table([sparse]) }.not_to raise_error
      expect(described_class.format_as_table([sparse])).to include('openai')
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
