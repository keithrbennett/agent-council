# frozen_string_literal: true

# Focused tests for the Codex-specific behavior in
# lib/agent_council/harnesses/codex_harness.rb (no model calls). The
# streams in spec/fixtures/codex were recorded from this harness's argv
# (codex-cli 0.167.0, ChatGPT login), with the thread ID zeroed and
# command items replaced by a placeholder git log; unsupported_model.jsonl
# with model no-such-model-xyz. Run with: rspec
require 'spec_helper'
require 'json'

RSpec.describe AgentCouncil::Harnesses::CodexHarness do
  def fixture(name)
    File.read(File.expand_path("../fixtures/codex/#{name}.jsonl", __dir__), encoding: 'UTF-8')
  end

  def stream(*events) = events.map { |event| "#{JSON.generate(event)}\n" }.join

  def message(text) = { 'type' => 'item.completed', 'item' => { 'type' => 'agent_message', 'text' => text } }

  def status(success, exitstatus = success ? 0 : 1)
    instance_double(Process::Status, success?: success, exitstatus: exitstatus)
  end

  def stub_mcp_list(out, err = '', success: true)
    allow(Open3).to receive(:capture3).with('codex', 'mcp', 'list',
      '--json').and_return([out, err, status(success)])
  end

  # Clears what prepare stored, so each example starts unprepared.
  after { described_class.instance_variable_set(:@mcp_server_names, nil) }

  describe '.argv' do
    before do
      stub_mcp_list(JSON.generate([{ 'name' => 'cov-loupe' }, { 'name' => 'my server' },
        { 'name' => 'a.b' }]))
      described_class.prepare
    end

    let(:argv) { described_class.argv('openai', 'gpt-5.6-terra') }

    def value_of(flag) = argv[argv.index(flag) + 1]

    it 'runs codex exec non-interactively with a JSONL stream, reading the prompt from stdin' do
      expect(argv.first(2)).to eq(%w[codex exec])
      expect(argv).to include('--json', '--ephemeral')
      expect(argv.last).to eq('-')
    end

    # pi and claude agents run outside a git repository; codex refuses to
    # without this flag.
    it 'runs outside a git repository' do
      expect(argv).to include('--skip-git-repo-check')
    end

    # Codex's configured sandbox_mode applies, as in an interactive
    # session (codex exec never asks for approval, whatever the config).
    it 'leaves the sandbox and approvals to Codex config' do
      expect(argv).not_to include('--sandbox', '-s', '--approve-for-me')
      expect(argv.grep(/\A(sandbox_mode|approval_policy)=/)).to be_empty
    end

    it 'passes the model, but not the provider, which only labels the agent' do
      expect(value_of('--model')).to eq('gpt-5.6-terra')
      expect(argv).not_to include('openai')
    end

    it 'turns off the bundled apps connectors' do
      expect(value_of('--disable')).to eq('apps')
    end

    # A dotted -c path can't name a server whose name needs quoting (codex
    # reads mcp_servers."my server".enabled as a new, transportless server
    # and fails); one table can, so every server goes in one.
    it 'turns off every configured MCP server in one -c table, quoting names that need it' do
      expect(argv.each_cons(2)).to include(
        ['-c', 'mcp_servers={cov-loupe={enabled=false},"my server"={enabled=false},"a.b"={enabled=false}}']
      )
    end

    # The user's config and AGENTS.md must load, as in an interactive session.
    it 'runs codex as an interactive session would, with user config' do
      expect(argv).not_to include('--ignore-user-config', '--ignore-rules')
    end

    it 'gives the shared scaffolding as developer instructions, as a TOML string' do
      override = argv.grep(/\Adeveloper_instructions=/).first
      value = override.delete_prefix('developer_instructions=')
      expect(JSON.parse(value)).to eq(AgentCouncil::Harnesses.scaffold_text)
    end

    it 'lists the servers once, in prepare, not per agent' do
      2.times { described_class.argv('openai', 'm') }
      expect(Open3).to have_received(:capture3).once
    end
  end

  describe '.prepare' do
    it 'passes no mcp_servers table when Codex has no servers configured' do
      stub_mcp_list('[]')
      expect(described_class.prepare).to be_nil
      argv = described_class.argv('p', 'm')
      expect(argv.grep(/\Amcp_servers=/)).to be_empty
      expect(argv.each_cons(2)).to include(%w[--disable apps])
    end

    # Failing closed: an agent run without the list would have its MCP servers on.
    it "says why when codex can't list its servers, and leaves argv unusable" do
      stub_mcp_list('', "WARNING: noise\nError: failed to load config\n", success: false)
      expect(described_class.prepare).to eq("codex: can't list Codex's MCP servers to turn them off: " \
                                            'Error: failed to load config')
      expect { described_class.argv('p', 'm') }.to raise_error(/prepare must run before argv/)
    end

    it 'puts a long error on one line, cut to 300 characters' do
      stub_mcp_list('', "Error: #{'y' * 400}\n", success: false)
      expect(described_class.prepare).to end_with("Error: #{'y' * 293}...")
    end

    it 'names the exit status when codex fails silently' do
      stub_mcp_list('', '', success: false)
      expect(described_class.prepare).to end_with('exited with status 1')
    end

    it 'fails when codex prints no JSON array, or cannot run' do
      stub_mcp_list('oops')
      expect(described_class.prepare).to end_with('its output is not JSON')
      stub_mcp_list('{}')
      expect(described_class.prepare).to end_with('its output is not a JSON array')
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      expect(described_class.prepare).to include('No such file or directory')
    end

    # Failing closed: a server it couldn't name would stay on.
    it 'fails on a server entry without a string name' do
      stub_mcp_list(JSON.generate([{ 'name' => 'a' }, { 'name' => 2 }]))
      expect(described_class.prepare).to end_with('it lists a server with no name: {"name":2}')
      stub_mcp_list(JSON.generate(['b']))
      expect(described_class.prepare).to end_with('it lists a server with no name: "b"')
    end

    it 'reads the listing as UTF-8 whatever the locale' do
      stub_mcp_list(JSON.generate([{ 'name' => 'café' }]).dup.force_encoding(Encoding::US_ASCII))
      expect(described_class.prepare).to be_nil
      expect(described_class.argv('p', 'm')).to include('mcp_servers={"café"={enabled=false}}')
    end
  end

  describe 'a successful agent' do
    let(:jsonl) { fixture('success') }

    it 'saves the last agent message, not the narration before tool calls' do
      expect(described_class.final_response(jsonl)).to start_with('Latest commit released version 0.2.0.')
      expect(described_class.assistant_messages(jsonl).size).to eq(2)
    end

    it 'reports usage with cached input subtracted from input, and no cost' do
      expect(described_class.usage(jsonl))
        .to eq('input' => 44_981 - 39_168, 'output' => 335, 'cache_read' => 39_168, 'cache_write' => 0)
    end

    # input_tokens is all input, so cache writes come out of it too.
    it 'subtracts cache writes from input as well' do
      usage = { 'input_tokens' => 110, 'cached_input_tokens' => 50, 'cache_write_input_tokens' => 10,
                'output_tokens' => 5 }
      expect(described_class.usage(stream({ 'type' => 'turn.completed', 'usage' => usage })))
        .to eq('input' => 50, 'output' => 5, 'cache_read' => 50, 'cache_write' => 10)
    end

    it 'has no error and no warnings' do
      expect(described_class.error_message(jsonl)).to be_nil
      expect(described_class.warnings(jsonl)).to eq([])
    end
  end

  describe 'an agent whose model the account cannot use' do
    let(:jsonl) { fixture('unsupported_model') }
    let(:reason) { "The 'no-such-model-xyz' model is not supported when using Codex with a ChatGPT account." }

    it 'gives the turn.failed reason, from the stream rather than the empty stderr' do
      expect(described_class.error_message(jsonl)).to eq(reason)
      expect(described_class.exit_detail(jsonl, '')).to eq(reason)
    end

    it 'saves nothing and reports no usage' do
      expect(described_class.final_response(jsonl)).to be_nil
      expect(described_class.usage(jsonl)).to be_nil
    end

    it 'warns of the non-fatal error item' do
      warnings = described_class.warnings(jsonl)
      expect(warnings.size).to eq(1)
      expect(warnings.first)
        .to start_with('Codex reported an error: Model metadata for `no-such-model-xyz` not found.')
    end
  end

  describe '.warnings' do
    def error_item(text) = { 'type' => 'item.completed', 'item' => { 'type' => 'error', 'message' => text } }

    it 'cuts each listed error to 200 characters' do
      expect(described_class.warnings(stream(error_item('x' * 5000))))
        .to eq(["Codex reported an error: #{'x' * 200}..."])
    end

    it 'lists at most five distinct errors in one warning' do
      jsonl = stream(*%w[a b a c d e f g].map { |text| error_item(text) })
      expect(described_class.warnings(jsonl)).to eq(['Codex reported errors: a; b; c; d; e; and 2 more'])
    end
  end

  describe '.error_message' do
    it 'flags a stream with no turn end, as for a killed agent' do
      expect(described_class.error_message(stream(message('partial')))).to include('no turn.completed')
      expect(described_class.final_response(stream(message('partial')))).to be_nil
    end

    it 'flags a completed turn with no text' do
      jsonl = stream(message('  '), { 'type' => 'turn.completed', 'usage' => {} })
      expect(described_class.error_message(jsonl)).to eq('the agent gave no final message')
    end

    it 'falls back to an error event when turn.failed gives no reason' do
      jsonl = stream({ 'type' => 'error', 'message' => 'boom' }, { 'type' => 'turn.failed' })
      expect(described_class.error_message(jsonl)).to eq('boom')
    end
  end

  describe '.exit_detail' do
    it 'uses stderr when the stream gives no reason, as for a bad flag' do
      expect(described_class.exit_detail('',
        "\nerror: unexpected argument\n")).to eq('error: unexpected argument')
      expect(described_class.exit_detail('', '')).to eq('no error output')
    end
  end

  it 'skips unparseable lines' do
    jsonl = "not json\n[1]\n#{stream(message('ok'), { 'type' => 'turn.completed' })}"
    expect(described_class.final_response(jsonl)).to eq('ok')
  end
end
