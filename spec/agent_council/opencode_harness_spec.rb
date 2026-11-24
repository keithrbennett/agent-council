# frozen_string_literal: true

# Focused tests for the OpenCode-specific behavior in
# lib/agent_council/harnesses/opencode_harness.rb (no model calls). The
# streams in spec/fixtures/opencode were recorded from this harness's argv
# and env before it turned snapshots off (ask_rejected.jsonl also before
# continue_loop_on_deny, below), so they carry snapshot hashes
# (opencode 1.19.6, opencode-go provider), with the session ID zeroed and
# tool output replaced by a placeholder; unknown_model.jsonl with model
# no-such-model-xyz. Run with: rspec
require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

RSpec.describe AgentCouncil::Harnesses::OpenCodeHarness do
  def fixture(name)
    File.read(File.expand_path("../fixtures/opencode/#{name}.jsonl", __dir__), encoding: 'UTF-8')
  end

  def stream(*events) = events.map { |event| "#{JSON.generate(event)}\n" }.join

  def text(message_id, text) = { 'type' => 'text', 'part' => { 'messageID' => message_id, 'text' => text } }

  def error(message)
    { 'type' => 'error', 'error' => { 'name' => 'APIError', 'data' => { 'message' => message } } }
  end

  describe '.argv' do
    let(:argv) { described_class.argv('opencode-go', 'glm-5.3') }

    it 'runs opencode run with a JSON event stream, the prompt coming from stdin' do
      expect(argv.first(2)).to eq(%w[opencode run])
      expect(argv.each_cons(2)).to include(%w[--format json])
    end

    # A default_agent in the user's or the project's config could name an
    # agent whose edit permission env doesn't deny.
    it 'pins the agent whose edit permission env denies' do
      expect(argv.each_cons(2)).to include(['--agent', described_class::AGENT])
    end

    it 'passes the provider and model as provider/model' do
      expect(argv.each_cons(2)).to include(['--model', 'opencode-go/glm-5.3'])
    end

    # A permission set to "ask" is rejected, as codex exec does.
    it 'auto-approves nothing' do
      expect(argv).not_to include('--auto', '--yolo', '--dangerously-skip-permissions')
    end
  end

  describe '.model_label' do
    it 'splits --model at its first "/" into provider and model' do
      expect(described_class.model_label(%w[opencode run --model zai/org/glm-5])).to eq('zai / org/glm-5')
    end

    it 'reads a --model without a "/" as the model alone' do
      expect(described_class.model_label(%w[opencode run --model glm-5])).to eq('glm-5')
    end
  end

  describe '.env' do
    let(:dir) { Dir.mktmpdir }
    let(:env) { described_class.env(dir) }
    let(:config) { JSON.parse(env['OPENCODE_CONFIG_CONTENT']) }

    after { FileUtils.rm_rf(dir) }

    it 'keeps the session in a database in the scratch dir' do
      expect(env['OPENCODE_DB']).to eq(File.join(dir, 'opencode.db'))
    end

    it 'adds the scaffolding as an instructions file it writes to the scratch dir' do
      expect(config['instructions'].size).to eq(1)
      expect(File.dirname(config['instructions'].first)).to eq(dir)
      expect(File.read(config['instructions'].first)).to eq(AgentCouncil::Harnesses.scaffold_text)
    end

    it 'denies edits, withholding the file-editing tools, and nothing else' do
      expect(config['permission']).to eq('edit' => 'deny')
    end

    # A per-agent permission comes after the global one, so a config's
    # agent.build.permission.edit would otherwise win.
    it 'denies edits for the pinned agent too' do
      expect(config['agent'][described_class::AGENT]['permission']).to include('edit' => 'deny')
    end

    # OpenCode's default asks for files outside the project. Per agent,
    # since a global map would replace a user's scalar value.
    it "allows the scratch dir as an external directory for the pinned agent's own tools" do
      expect(config['agent'][described_class::AGENT]['permission'])
        .to include('external_directory' => { File.join(dir, '*') => 'allow' })
    end

    # Its request isn't in the stream, so not in usage.
    it 'disables the title agent' do
      expect(config['agent']['title']).to eq('disable' => true)
    end

    it 'turns off snapshots' do
      expect(config['snapshot']).to be(false)
    end

    # Otherwise a tool call set to ask, which opencode run refuses, ends
    # the session.
    it 'lets the agent go on after a refused tool call' do
      expect(config['experimental']).to eq('continue_loop_on_deny' => true)
    end

    it 'leaves an inherited OPENCODE_PERMISSION alone' do
      expect(env).not_to have_key('OPENCODE_PERMISSION')
    end
  end

  describe '.final_response' do
    it 'is nil without text' do
      expect(described_class.final_response(stream(text('m1', '  ')))).to be_nil
    end

    it 'is the last message with text in a recorded run' do
      expect(described_class.final_response(fixture('success'))).to eq('README.md has 1362 lines.')
    end

    it "joins the last message's text parts, skipping earlier messages and blank parts" do
      jsonl = stream(text('m1', 'narration'), text('m2', 'part one'), text('m2', ' '), text('m2', 'part two'))
      expect(described_class.final_response(jsonl)).to eq("part one\npart two")
    end

    it 'skips ignored parts' do
      ignored = { 'type' => 'text', 'part' => { 'messageID' => 'm2', 'text' => 'x', 'ignored' => true } }
      expect(described_class.final_response(stream(text('m1', 'report'), ignored))).to eq('report')
    end

    it 'skips synthetic parts, which OpenCode writes itself' do
      synthetic = { 'type' => 'text',
                    'part' => { 'messageID' => 'm2', 'text' => 'Continue', 'synthetic' => true } }
      expect(described_class.final_response(stream(text('m1', 'report'), synthetic))).to eq('report')
    end

    it 'is nil after an error, even with earlier text' do
      expect(described_class.final_response(stream(text('m1', 'partial'), error('boom')))).to be_nil
    end

    it 'skips unparseable lines' do
      expect(described_class.final_response("not json\n[1]\n#{stream(text('m1', 'ok'))}")).to eq('ok')
    end
  end

  describe '.usage' do
    # Recorded: inputs 10703 + 27192 + 6253, outputs 23+61 + 30+33 + 10.
    it 'sums the steps, counting reasoning as output, with their cost' do
      usage = described_class.usage(fixture('success'))
      expect(usage.except('cost')).to eq('input' => 44_148, 'output' => 157, 'cache_read' => 27_072,
        'cache_write' => 0)
      expect(usage['cost']).to be > 0
    end

    it 'leaves out a zero cost' do
      step = { 'tokens' => { 'input' => 5, 'output' => 1 }, 'cost' => 0 }
      expect(described_class.usage(stream({ 'type' => 'step_finish', 'part' => step })))
        .to eq('input' => 5, 'output' => 1, 'cache_read' => 0, 'cache_write' => 0)
    end

    it 'is nil without usage' do
      expect(described_class.usage(fixture('unknown_model'))).to be_nil
    end
  end

  describe '.error_message' do
    it 'is nil for a recorded success' do
      expect(described_class.error_message(fixture('success'))).to be_nil
    end

    it "is an error event's message" do
      expect(described_class.error_message(fixture('unknown_model')))
        .to eq('Unexpected server error. Check server logs for details.')
    end

    it "falls back to the error's name, then a placeholder" do
      expect(described_class.error_message(stream({ 'type' => 'error', 'error' => { 'name' => 'Aborted' } })))
        .to eq('Aborted')
      expect(described_class.error_message(stream({ 'type' => 'error' })))
        .to eq('an error event gave no reason')
    end

    %w[length content-filter error].each do |reason|
      it "reports a last request that finished for #{reason}, despite its text" do
        jsonl = stream(text('m1', 'partial'), { 'type' => 'step_finish', 'part' => { 'reason' => reason } })
        expect(described_class.error_message(jsonl)).to eq("stopped early (reason: #{reason})")
      end
    end

    it 'reports a cut-off message whose text is the report, though a later request completed' do
      cut = { 'type' => 'step_finish', 'part' => { 'messageID' => 'm1', 'reason' => 'length' } }
      stop = { 'type' => 'step_finish', 'part' => { 'messageID' => 'm2', 'reason' => 'stop' } }
      expect(described_class.error_message(stream(text('m1', 'partial'), cut, stop)))
        .to eq('stopped early (reason: length)')
    end

    it 'accepts an earlier cut-off request that a later one completed' do
      cut = { 'type' => 'step_finish', 'part' => { 'messageID' => 'm1', 'reason' => 'length' } }
      stop = { 'type' => 'step_finish', 'part' => { 'messageID' => 'm2', 'reason' => 'stop' } }
      expect(described_class.error_message(stream(cut, text('m2', 'report'), stop))).to be_nil
    end

    # run_agent then says whether the stream had any assistant message.
    it 'leaves a stream with no text to run_agent' do
      expect(described_class.error_message('')).to be_nil
    end
  end

  # Recorded with the project's opencode.json setting bash to ask, before
  # env set continue_loop_on_deny: the model's lead-in, the rejected call,
  # and a session ended at tool-calls, exit 0.
  describe 'a refused ask permission' do
    let(:jsonl) { fixture('ask_rejected') }

    it 'fails the agent, naming the tool' do
      expect(described_class.error_message(jsonl))
        .to eq('stopped when OpenCode refused a tool call its permissions set to ask (bash)')
    end

    it 'warns of the refused call' do
      expect(described_class.warnings(jsonl))
        .to eq(['OpenCode refused a tool call for want of permission (bash)'])
    end

    it 'warns once of several refused calls, with their count and tools' do
      rejected = ->(tool) {
        { 'type' => 'tool_use', 'part' => { 'tool' => tool, 'state' => {
          'status' => 'error', 'error' => described_class::REJECTION_PREFIX
        } } }
      }
      expect(described_class.warnings(stream(rejected.('read'), rejected.('read'), rejected.('bash'))))
        .to eq(['OpenCode refused 3 tool calls for want of permission (read, bash)'])
    end

    it "names only the last request's rejected calls as the stop's cause" do
      rejected = { 'type' => 'tool_use', 'part' => { 'messageID' => 'm1', 'tool' => 'read', 'state' => {
        'status' => 'error', 'error' => described_class::REJECTION_PREFIX
      } } }
      steps = [{ 'type' => 'step_finish', 'part' => { 'messageID' => 'm1', 'reason' => 'tool-calls' } },
        { 'type' => 'step_finish', 'part' => { 'messageID' => 'm2', 'reason' => 'tool-calls' } }]
      expect(described_class.error_message(stream(rejected,
        *steps))).to eq('stopped early (reason: tool-calls)')
    end

    it 'fails a session otherwise ended at tool calls' do
      jsonl = stream(text('m1', 'lead-in'),
        { 'type' => 'step_finish', 'part' => { 'reason' => 'tool-calls' } })
      expect(described_class.error_message(jsonl)).to eq('stopped early (reason: tool-calls)')
    end
  end

  describe '.exit_detail' do
    it 'prefers the stream error to stderr' do
      expect(described_class.exit_detail(fixture('unknown_model'), "trace\n"))
        .to eq('Unexpected server error. Check server logs for details.')
    end

    it "falls back to stderr's first nonblank line" do
      expect(described_class.exit_detail('', "\n  bad flag\nmore\n")).to eq('bad flag')
      expect(described_class.exit_detail('', '')).to eq('no error output')
    end
  end

  it 'has no warnings for a recorded success' do
    expect(described_class.warnings(fixture('success'))).to eq([])
  end
end
