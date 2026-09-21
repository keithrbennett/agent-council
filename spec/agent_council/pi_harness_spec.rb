# frozen_string_literal: true

# Focused tests for the pi-specific behavior in
# lib/agent_council/harnesses/pi_harness.rb (no model calls). Run with: rspec

require_relative '../../lib/agent_council/harnesses/pi_harness'

RSpec.describe AgentCouncil::Harnesses::PiHarness do
  # Captured shape of a pi --mode json event stream (pi 0.84.4), trimmed to
  # the relevant events: a tool-use turn (first assistant message_end) and
  # the final turn (second assistant message_end).
  let(:sample_stream) do
    <<~JSONL
      {"type":"session","version":3,"id":"01a05e0f","timestamp":"2026-09-01T17:40:58.973Z","cwd":"/repo"}
      {"type":"agent_start"}
      {"type":"turn_start"}
      {"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"the prompt"}],"timestamp":1}}
      {"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"the prompt"}],"timestamp":1}}
      {"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"I should read files"},{"type":"toolcall","name":"read"}],"stopReason":"toolUse","timestamp":2}}
      {"type":"tool_execution_end","toolCallId":"1","toolName":"read","result":"...","isError":false}
      {"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"now I know"},{"type":"text","text":"# Report\\n\\nFirst part."},{"type":"text","text":" Second part."}],"stopReason":"stop","timestamp":3}}
      {"type":"turn_end","message":{"role":"assistant"},"toolResults":[]}
      {"type":"agent_end","messages":[]}
      {"type":"agent_settled"}
    JSONL
  end

  describe '.argv' do
    let(:argv) { described_class.argv('zai', 'glm-5.3', '/tmp/scratch-xyz') }

    it 'invokes pi non-interactively with a JSON event stream and no session' do
      expect(argv.first).to eq('pi')
      expect(argv).to include('-p', '--no-session')
      expect(argv.each_cons(2)).to include(['--mode', 'json'])
    end

    it 'selects the configured provider and model' do
      expect(argv[argv.index('--provider') + 1]).to eq('zai')
      expect(argv[argv.index('--model') + 1]).to eq('glm-5.3')
    end

    # Safety-critical: agents must be analyzers, not modifiers.
    it 'allowlists read-only tools and withholds edit/write' do
      tools = argv[argv.index('--tools') + 1].split(',')
      expect(tools).to contain_exactly('read', 'grep', 'find', 'ls', 'bash')
    end
  end

  describe '.scaffold_text' do
    subject(:scaffold) { described_class.scaffold_text('/tmp/scratch-xyz') }

    it 'names the unique scratch dir' do
      expect(scaffold).to include('/tmp/scratch-xyz')
    end

    # Safety-critical invariants; deliberate rewording should update these.
    it 'states the read-only rules' do
      expect(scaffold).to match(/do not modify/i)
      expect(scaffold).to match(/test suites/i) # no stateful commands
    end

    it 'requires the analysis as the final message, not a file' do
      expect(scaffold).to match(/final message/i)
    end
  end

  describe '.assistant_messages' do
    it 'returns assistant messages from message_end events, in order' do
      messages = described_class.assistant_messages(sample_stream)
      expect(messages.size).to eq(2) # the user message is excluded
      expect(messages.map { |m| m['stopReason'] }).to eq(%w[toolUse stop])
    end

    it 'skips unparseable lines' do
      expect(described_class.assistant_messages("garbage\n" + sample_stream).size).to eq(2)
    end

    it 'skips JSON lines that parse to non-objects' do
      stream = "123\n\"str\"\n[1,2]\nnull\n" + sample_stream
      expect(described_class.assistant_messages(stream).size).to eq(2)
    end
  end

  describe '.final_response' do
    it 'takes the text blocks of the last assistant message' do
      # Multiple text blocks in one message are joined with "\n".
      expect(described_class.final_response(sample_stream))
        .to eq("# Report\n\nFirst part.\n Second part.")
    end

    it 'ignores user messages and thinking blocks' do
      text = described_class.final_response(sample_stream)
      expect(text).not_to include('the prompt')
      expect(text).not_to include('now I know')
    end

    it 'falls back to an earlier assistant message when the last one has no text' do
      # Seen in the wild: some models occasionally answer in a thinking
      # block only (e.g. zai/glm-4.7); the report must not be blank.
      stream = <<~JSONL
        {"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"real report"}],"stopReason":"toolUse"}}
        {"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}],"stopReason":"stop"}}
      JSONL
      expect(described_class.final_response(stream)).to eq('real report')
    end

    it 'returns nil when there is no assistant text' do
      stream = <<~JSONL
        {"type":"session","version":3,"id":"x","timestamp":"t","cwd":"/repo"}
        {"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
      JSONL
      expect(described_class.final_response(stream)).to be_nil
    end

    it 'skips unparseable lines' do
      stream = "not json\n" \
               '{"type":"message_end","message":{"role":"assistant",' \
               '"content":[{"type":"text","text":"ok"}]}}' \
               "\n"
      expect(described_class.final_response(stream)).to eq('ok')
    end
  end

  describe '.error_message' do
    it 'surfaces provider errors' do
      stream = <<~JSONL
        {"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"400 model_not_available_for_integrator"}}
        {"type":"agent_end","messages":[]}
      JSONL
      expect(described_class.error_message(stream)).to eq('400 model_not_available_for_integrator')
    end

    it 'returns the last error when several occurred' do
      stream = <<~JSONL
        {"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"first"}}
        {"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"second"}}
      JSONL
      expect(described_class.error_message(stream)).to eq('second')
    end

    it 'returns nil when there are no errors' do
      expect(described_class.error_message(sample_stream)).to be_nil
    end
  end
end
