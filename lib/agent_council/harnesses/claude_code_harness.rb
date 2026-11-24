# frozen_string_literal: true

# AgentCouncil::Harnesses::ClaudeCodeHarness — all knowledge specific to
# the Claude Code harness: how to invoke the claude CLI for one agent,
# with its tool allowlist and the shared read-only scaffolding, and how to
# read its stream-json output afterward.
#
# AgentCouncil is harness-agnostic and finds this class through
# AgentCouncil::Harnesses (lib/agent_council/harnesses.rb), by its NAME.
# Authentication and billing are left to Claude Code: an agent bills however
# claude would at the user's terminal.

require_relative 'harness'

module AgentCouncil
  module Harnesses
    class ClaudeCodeHarness < Harness
      NAME = 'claude'

      # Analysis toolset (Claude Code's built-in tool names): Edit, Write, and
      # the rest are absent. Bash, a full shell, stays for investigation;
      # only the scaffolding text asks the model to use it read-only.
      TOOLS = 'Read,Grep,Glob,Bash'

      # Invocation for one agent. The substantive prompt is not part of
      # argv; it is piped to stdin. provider is not passed: Claude Code
      # takes none, so an entry's provider only labels the agent (e.g.
      # bedrock, for a claude set up to use it).
      def self.argv(_provider, model)
        [
          NAME,
          '-p',                              # non-interactive: process prompt and exit
          '--output-format', 'stream-json',  # JSONL event stream on stdout
          '--verbose',                       # required by stream-json with -p
          '--no-session-persistence',        # ephemeral: no session saved
          '--tools', TOOLS,                  # the only built-in tools available
          '--allowedTools', TOOLS,           # ...and pre-approved, since -p can't ask
          '--permission-mode', 'manual',     # the same for every user, whatever their defaultMode
          '--model', model,
          '--append-system-prompt', Harnesses.scaffold_text
        ]
      end

      # Variables for the agent's process beyond TMPDIR: the scratch dir as
      # CLAUDE_CODE_TMPDIR, the base under which Claude Code's sandbox makes
      # the writable TMPDIR it gives commands. Without it, a user's own
      # CLAUDE_CODE_TMPDIR would put that dir outside the scratch dir,
      # shared and never cleaned up.
      def self.env(scratch_dir)
        { 'CLAUDE_CODE_TMPDIR' => scratch_dir }
      end

      # --- event stream reading ---

      # The agent's result event: the last one, which ends the stream. nil if
      # there is none, e.g. for an agent that was killed.
      def self.result_event(jsonl)
        events(jsonl).reverse_each.detect { |event| event['type'] == 'result' }
      end
      private_class_method :result_event

      # The messages of the stream's assistant events, in order (several per
      # model request, one per content block).
      def self.assistant_messages(jsonl)
        events(jsonl).filter_map do |event|
          message = event['message'] if event['type'] == 'assistant'
          message if message.is_a?(Hash)
        end
      end

      # The final response: the result event's text, for an agent that didn't
      # fail.
      def self.final_response(jsonl)
        result = result_event(jsonl)
        return nil unless result && result['is_error'] != true

        text = result['result']
        text.is_a?(String) ? text : nil
      end

      # Our usage keys, each mapped to Claude Code's name for it. Its input
      # excludes cache reads and writes, as pi's does.
      USAGE_KEYS = { 'input' => 'input_tokens', 'output' => 'output_tokens',
                     'cache_read' => 'cache_read_input_tokens',
                     'cache_write' => 'cache_creation_input_tokens' }.freeze

      # Token usage as AgentCouncil expects it (see Harness), from the
      # result event alone: it totals all the agent's requests, while the assistant
      # events' usage is per-message snapshots that undercount output. nil
      # when the stream has no result event (as for an agent whose claude was
      # killed: no usage beats an undercount) or reports no usage (as when
      # the agent never reached a model).
      def self.usage(jsonl)
        result = result_event(jsonl)
        usage = result && result['usage']
        return nil unless usage.is_a?(Hash)

        totals = USAGE_KEYS.transform_values { |key| count(usage[key]) }
        return nil if totals.values.all?(&:zero?)

        cost = count(result['total_cost_usd'])
        cost.positive? ? totals.merge('cost' => cost.round(6)) : totals
      end

      # Why the agent produced no usable report, or nil. A failed agent has a
      # result event with is_error true (its subtype is usually still
      # "success", so it isn't checked); one that isn't flagged but has no
      # text is reported as such, since the report is that text. The reason
      # is its errors, if any (e.g. the turn limit, with no result text),
      # otherwise its result text (e.g. "Not logged in · Please run
      # /login").
      def self.error_message(jsonl)
        result = result_event(jsonl)
        return 'the stream has no result event' unless result
        return error_reason(result) || 'the agent failed and gave no reason' if result['is_error'] == true

        text = result['result']
        'the result event has no text' unless text.is_a?(String) && !text.strip.empty?
      end

      # The reason a failed agent's result event gives, or nil if it gives none.
      def self.error_reason(result)
        errors = Array(result['errors']).grep(String).map(&:strip).reject(&:empty?)
        return errors.join('; ') unless errors.empty?

        text = result['result']
        text if text.is_a?(String) && !text.strip.empty?
      end
      private_class_method :error_reason

      # Why an agent that exited nonzero failed. Claude Code explains a failure
      # in a result event with is_error true, and its stderr is then
      # usually empty, so that reason, if it gives one, comes first.
      # Otherwise stderr is likelier to say why (e.g. for a crash) than
      # whatever else the stream shows (e.g. a result with no text), which
      # is the last resort. Returned whole: the caller puts it on one line
      # and shortens it (see Harness).
      def self.exit_detail(stdout, stderr)
        result = result_event(stdout)
        reason = error_reason(result) if result && result['is_error'] == true
        return reason if reason

        first_line(stderr) || (error_message(stdout) if result) || NO_ERROR_OUTPUT
      end

      # Warnings about an agent, succeeded or not: the tool calls Claude Code
      # refused, which -p mode can't ask about. The agent usually still
      # succeeds (the model saw the refusal and answered without that
      # call), but its report may be missing what the call would have
      # found; an agent that fails (say, out of turns) may have failed
      # because of them.
      def self.warnings(jsonl)
        result = result_event(jsonl)
        denials = result && result['permission_denials']
        return [] unless denials.is_a?(Array) && !denials.empty?

        calls = denials.map { |denial| denied_call(denial) }.uniq
        listed = calls.first(MAX_LISTED_CALLS).map do |tool, target|
          target ? "#{tool} (#{shorten(target, MAX_TARGET_LENGTH)})" : tool
        end
        listed << "and #{calls.size - listed.size} more" if calls.size > listed.size
        ["Claude Code refused #{denials.size} tool call#{'s' unless denials.size == 1}: #{listed.join('; ')}"]
      end

      # Distinct refused calls named in a warning, so an agent refused many
      # times still gets a warning of a readable length.
      MAX_LISTED_CALLS = 5

      # Characters of a refused call's target a warning shows.
      MAX_TARGET_LENGTH = 80

      # The tool_input keys that say what a refused call was for, in order
      # of preference: Bash's command, Read's file_path, then Grep's and
      # Glob's pattern and path.
      TARGET_KEYS = %w[command file_path pattern path].freeze

      # A refused tool call as [tool, target]: its tool and what it was for,
      # such as a Bash command or the file a Read asked for, on one line,
      # or nil if the call gives none. Compared whole, so calls that differ
      # only past where a warning shortens them still count as different.
      def self.denied_call(denial)
        return ['unknown tool', nil] unless denial.is_a?(Hash)

        tool = denial['tool_name'].is_a?(String) ? denial['tool_name'] : 'unknown tool'
        input = denial['tool_input']
        target = TARGET_KEYS.map { |key| input[key] }.grep(String).first if input.is_a?(Hash)
        target = target&.gsub(/\s+/, ' ')&.strip
        [tool, (target unless target.nil? || target.empty?)]
      end
      private_class_method :denied_call
    end
  end
end
