# frozen_string_literal: true

# Focused tests for the Claude Code-specific behavior in
# lib/agent_council/harnesses/claude_code_harness.rb (no model calls). The
# streams in spec/fixtures/claude_code were recorded from real
# `claude -p --output-format stream-json --verbose` invocations (Claude Code
# 2.1.325), trimmed to a few event types and fields, with local paths
# replaced by /repo and /tmp/scratch, tool call IDs renumbered, and commit
# hashes zeroed. denied.jsonl was recorded with this harness's argv in a
# repository whose .claude/settings.json denies Bash(cat:*); the others
# with similar flags (max_turns with --max-turns 1, output_limit with
# CLAUDE_CODE_MAX_OUTPUT_TOKENS=100). Run with: rspec
require 'spec_helper'
require 'json'

RSpec.describe AgentCouncil::Harnesses::ClaudeCodeHarness do
  def fixture(name)
    File.read(File.expand_path("../fixtures/claude_code/#{name}.jsonl", __dir__), encoding: 'UTF-8')
  end

  # A stream of just a result event with the given fields.
  def result_stream(fields)
    "#{JSON.generate({ 'type' => 'result', 'subtype' => 'success' }.merge(fields))}\n"
  end

  describe '.argv' do
    let(:argv) { described_class.argv('anthropic', 'claude-opus-5-5') }

    def value_of(flag) = argv[argv.index(flag) + 1]

    it 'invokes claude non-interactively with a JSON event stream and no saved session' do
      expect(argv.first).to eq('claude')
      expect(argv).to include('-p', '--verbose', '--no-session-persistence')
      expect(value_of('--output-format')).to eq('stream-json')
    end

    it 'selects the configured model and passes no provider' do
      expect(value_of('--model')).to eq('claude-opus-5-5')
      expect(argv).not_to include('anthropic')
    end

    # Safety-critical: agents must be analyzers, not modifiers.
    it 'offers only read-only built-in tools plus Bash, all usable without asking' do
      expect(value_of('--tools').split(',')).to contain_exactly('Read', 'Grep', 'Glob', 'Bash')
      expect(value_of('--allowedTools')).to eq(value_of('--tools'))
    end

    # manual is what claude --help calls the mode its stream reports as default.
    it "uses the manual permission mode, whatever the user's own" do
      expect(value_of('--permission-mode')).to eq('manual')
    end

    it 'loads no MCP servers' do
      expect(argv).to include('--strict-mcp-config')
      expect(argv).not_to include('--mcp-config')
    end

    # CLAUDE.md must load, as in an interactive session; --bare skips it.
    it 'runs claude as an interactive session would, not bare' do
      expect(argv).not_to include('--bare')
    end

    it 'appends the shared scaffolding to the system prompt' do
      expect(argv.last).to eq(AgentCouncil::Harnesses.scaffold_text)
      expect(argv[-2]).to eq('--append-system-prompt')
    end

    # In a separate process, so nothing else of agent-council is loaded.
    it 'works with only its own file required' do
      lib = File.expand_path('../../lib', __dir__)
      script = "require 'agent_council/harnesses/claude_code_harness'; " \
               "print AgentCouncil::Harnesses::ClaudeCodeHarness.argv('p', 'm').last"
      out, err, status = Open3.capture3(RbConfig.ruby, '-I', lib, '-e', script)
      expect(status).to be_success, err
      expect(out).to eq(AgentCouncil::Harnesses.scaffold_text)
    end
  end

  describe 'a successful agent' do
    let(:stream) { fixture('success') }

    it "reads the result event's text as the final response" do
      expect(described_class.final_response(stream)).to start_with('The command printed `42`.')
    end

    it 'reports no error and no warnings' do
      expect(described_class.error_message(stream)).to be_nil
      expect(described_class.warnings(stream)).to eq([])
    end

    it "reads the agent's usage and cost from the result event" do
      expect(described_class.usage(stream)).to eq('input' => 4, 'output' => 161, 'cache_read' => 16_151,
        'cache_write' => 2224, 'cost' => 0.000687)
    end

    it 'reads usage without a cost when the agent has none' do
      usage = { 'input_tokens' => 5, 'output_tokens' => 7 }
      expect(described_class.usage(result_stream('usage' => usage, 'total_cost_usd' => 0)))
        .to eq('input' => 5, 'output' => 7, 'cache_read' => 0, 'cache_write' => 0)
      expect(described_class.usage(result_stream('usage' => usage))).not_to have_key('cost')
    end

    it 'finds its assistant messages' do
      expect(described_class.assistant_messages(stream)).to all(include('role' => 'assistant'))
      expect(described_class.assistant_messages(stream)).not_to be_empty
    end
  end

  describe 'failed agents' do
    # Every failure recorded exited 1; exit_detail is what reports them.
    {
      'not_logged_in' => 'Not logged in · Please run /login',
      'unknown_model' => /\AThere's an issue with the selected model \(claude-nonexistent-9\)/,
      'max_turns'     => 'Reached maximum number of turns (1)',
      'output_limit'  => /\AAPI Error: Claude's response exceeded the 100 output token maximum/,
    }.each do |name, reason|
      it "explains a #{name.tr('_', ' ')} failure from its stream" do
        stream = fixture(name)
        expect(described_class.error_message(stream)).to match(reason)
        expect(described_class.exit_detail(stream, '')).to match(reason)
        expect(described_class.final_response(stream)).to be_nil
      end
    end

    it 'prefers the stream to stderr' do
      expect(described_class.exit_detail(fixture('unknown_model'), "[claude-code:unrecognized_model] {}\n"))
        .to start_with("There's an issue")
    end

    it 'still reads the usage of a failed agent that reached the model' do
      expect(described_class.usage(fixture('max_turns'))).to include('output' => 184)
    end

    it 'reports no usage for an agent that never reached a model' do
      expect(described_class.usage(fixture('not_logged_in'))).to be_nil
    end

    it 'falls back to stderr when the stream has no result event' do
      expect(described_class.exit_detail('', "\nfatal: crashed\n")).to eq('fatal: crashed')
      expect(described_class.exit_detail('not json', '')).to eq('no error output')
    end

    it 'falls back to stderr when the result event reports no error' do
      expect(described_class.exit_detail(result_stream('is_error' => false, 'result' => 'ok'), 'oops'))
        .to eq('oops')
    end

    it 'falls back to stderr when a failed result event gives no reason' do
      stream = result_stream('is_error' => true, 'result' => ' ', 'errors' => [])
      expect(described_class.exit_detail(stream, "real cause\n")).to eq('real cause')
      expect(described_class.exit_detail(stream, '')).to eq('the agent failed and gave no reason')
    end

    it "prefers stderr to the stream's other problems, which it falls back to without stderr" do
      stream = result_stream('is_error' => false, 'result' => ' ')
      expect(described_class.exit_detail(stream, "real cause\n")).to eq('real cause')
      expect(described_class.exit_detail(stream, '')).to eq('the result event has no text')
    end

    # run_agent puts it on one line and shortens it (failure_reason).
    it 'returns a reason whole' do
      reason = "line one\n\n  line two #{'x' * 400}"
      stream = result_stream('is_error' => true, 'result' => reason)
      expect(described_class.exit_detail(stream, '')).to eq(reason)
    end

    it 'treats a stream without a result event as failed' do
      stream = fixture('success').lines.reject { |line| line.include?('"type":"result"') }.join
      expect(described_class.error_message(stream)).to eq('the stream has no result event')
      expect(described_class.final_response(stream)).to be_nil
      expect(described_class.usage(stream)).to be_nil
    end

    it 'reports a result event that is not an error but has no text' do
      stream = fixture('success').sub(/"result":"[^"]*"/, '"result":" "')
      expect(described_class.error_message(stream)).to eq('the result event has no text')
      expect(described_class.error_message(result_stream('is_error' => false)))
        .to eq('the result event has no text')
    end

    it 'gives a reason for an error that states none' do
      stream = result_stream('is_error' => true, 'result' => ' ', 'errors' => [])
      expect(described_class.error_message(stream)).to eq('the agent failed and gave no reason')
    end

    it 'joins several errors' do
      stream = result_stream('is_error' => true, 'errors' => ['one', ' ', 'two'])
      expect(described_class.error_message(stream)).to eq('one; two')
    end
  end

  describe '.warnings' do
    it 'warns of the tool calls Claude Code refused for an agent that succeeded' do
      stream = fixture('denied')
      expect(described_class.error_message(stream)).to be_nil
      expect(described_class.warnings(stream))
        .to eq(['Claude Code refused 1 tool call: Bash (cat README.md)'])
    end

    it 'gives none when the result event lists no refusals, or has no list' do
      expect(described_class.warnings(result_stream('is_error' => false, 'permission_denials' => [])))
        .to eq([])
      expect(described_class.warnings(result_stream('is_error' => false))).to eq([])
      expect(described_class.warnings('')).to eq([])
    end

    it 'lists each refused call once, counting them all, and shortens long commands' do
      long = { 'tool_name' => 'Bash', 'tool_input' => { 'command' => "echo #{'y' * 100}" } }
      denials = [long, long, { 'tool_name' => 'WebFetch', 'tool_input' => { 'url' => 'u' } }, 'junk']
      stream = result_stream('is_error' => false, 'permission_denials' => denials)
      warning = described_class.warnings(stream).first
      expect(warning).to start_with('Claude Code refused 4 tool calls: Bash (echo yyy')
      expect(warning).to end_with('...); WebFetch; unknown tool')
    end

    it 'tells apart calls that differ only past where they are shortened, and skips blank commands' do
      bash = ->(command) { { 'tool_name' => 'Bash', 'tool_input' => { 'command' => command } } }
      prefix = "echo #{'z' * 90}"
      stream = result_stream('is_error' => false,
        'permission_denials' => [bash.call("#{prefix} 1"), bash.call("#{prefix} 2"), bash.call('  ')])
      warning = described_class.warnings(stream).first
      expect(warning.scan('Bash (echo zzz').size).to eq(2)
      expect(warning).to end_with('...); Bash')
    end

    it 'names at most five distinct calls, counting the rest' do
      denials = (1..8).map { |n| { 'tool_name' => 'Bash', 'tool_input' => { 'command' => "cmd#{n}" } } }
      stream = result_stream('is_error' => false, 'permission_denials' => denials)
      expect(described_class.warnings(stream)).to eq(['Claude Code refused 8 tool calls: Bash (cmd1); ' \
        'Bash (cmd2); Bash (cmd3); Bash (cmd4); Bash (cmd5); and 3 more'])
    end

    it 'names the file, or pattern, a refused Read, Grep, or Glob call was for' do
      denials = [
        { 'tool_name' => 'Read', 'tool_input' => { 'file_path' => '/repo/.env' } },
        { 'tool_name' => 'Grep', 'tool_input' => { 'pattern' => 'secret', 'path' => '/repo' } },
        { 'tool_name' => 'Glob', 'tool_input' => { 'path' => '/repo/keys' } },
      ]
      stream = result_stream('is_error' => false, 'permission_denials' => denials)
      expect(described_class.warnings(stream))
        .to eq(['Claude Code refused 3 tool calls: Read (/repo/.env); Grep (secret); Glob (/repo/keys)'])
    end
  end
end
