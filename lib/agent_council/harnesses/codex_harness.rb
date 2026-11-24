# frozen_string_literal: true

# AgentCouncil::Harnesses::CodexHarness — all knowledge specific to the
# OpenAI Codex CLI harness: how to invoke `codex exec` for one agent,
# with the shared scaffolding, and how to read
# its --json event stream afterward.
#
# AgentCouncil is harness-agnostic and finds this class through
# AgentCouncil::Harnesses (lib/agent_council/harnesses.rb), by its NAME.
# Authentication and billing are left to Codex: an agent bills however
# codex would at the user's terminal (ChatGPT plan or API key).

require 'json'
require_relative 'harness'

module AgentCouncil
  module Harnesses
    class CodexHarness < Harness
      NAME = 'codex'

      # Invocation for one agent. The substantive prompt is not part of
      # argv; it is piped to stdin ('-'). provider is not passed: like
      # Claude Code's, an entry's provider only labels the agent, and Codex
      # uses the model_provider its own config names.
      #
      # No --sandbox or approval flags: the user's sandbox_mode applies, as
      # in an interactive session, along with the rest of their config.toml
      # (MCP servers and plugins included) and the repository's AGENTS.md.
      # Their approval_policy doesn't: codex exec never asks, so a command
      # that needs approval is refused. Under workspace-write,
      # Codex lets commands write $TMPDIR, which the scaffolding sends
      # agents to; under read-only nothing is writable.
      #
      # developer_instructions replaces any the user's config sets; Codex
      # has no way to append to it.
      def self.argv(_provider, model)
        [
          NAME, 'exec',
          '--json',                  # JSONL event stream on stdout
          '--ephemeral',             # no session files saved; subagents then fail to spawn
          '--skip-git-repo-check',   # run anywhere, as pi and claude agents do
          '--color', 'never',
          '--model', model,
          '-c', "developer_instructions=#{toml_string(Harnesses.scaffold_text)}",
          '-' # read the prompt from stdin
        ]
      end

      # A TOML basic string (JSON's string escapes are valid TOML ones), so
      # -c reads the value as the string itself, not as TOML to parse.
      def self.toml_string(text)
        JSON.generate(text)
      end
      private_class_method :toml_string

      # --- event stream reading ---

      # The completed items of the given type, in order.
      def self.completed_items(jsonl, type)
        events(jsonl).filter_map do |event|
          item = event['item'] if event['type'] == 'item.completed'
          item if item.is_a?(Hash) && item['type'] == type
        end
      end
      private_class_method :completed_items

      # The agent's messages (its text between and after tool calls), in order.
      def self.assistant_messages(jsonl)
        completed_items(jsonl, 'agent_message')
      end

      # The event that ended the agent's turn: turn.completed or
      # turn.failed. nil if there is none, e.g. for an agent that was killed.
      def self.turn_end(jsonl)
        events(jsonl).reverse_each.detect { |event| %w[turn.completed turn.failed].include?(event['type']) }
      end
      private_class_method :turn_end

      # The final response: the last agent message with text, for an agent
      # whose turn completed. Earlier messages narrate its tool use.
      def self.final_response(jsonl)
        return nil unless turn_end(jsonl)&.fetch('type') == 'turn.completed'

        message = assistant_messages(jsonl).reverse_each.detect { |m| text_of(m) }
        message && text_of(message)
      end

      # A message's text, or nil if it has none.
      def self.text_of(item)
        text = item['text']
        text if text.is_a?(String) && !text.strip.empty?
      end
      private_class_method :text_of

      # Token usage as AgentCouncil expects it (see Harness), from the
      # turn.completed event, which totals the turn's requests. Codex's
      # input_tokens is all input, OpenAI's convention, so the cached reads
      # and writes it reports are subtracted from it; reasoning tokens are
      # part of output_tokens. Codex prices nothing, so there is no 'cost'.
      # nil when the turn didn't complete or reports no usage.
      def self.usage(jsonl)
        turn = turn_end(jsonl)
        usage = turn['usage'] if turn && turn['type'] == 'turn.completed'
        return nil unless usage.is_a?(Hash)

        cache_read = count(usage['cached_input_tokens'])
        cache_write = count(usage['cache_write_input_tokens'])
        totals = { 'input'       => [count(usage['input_tokens']) - cache_read - cache_write, 0].max,
                   'output'      => count(usage['output_tokens']),
                   'cache_read'  => cache_read,
                   'cache_write' => cache_write }
        totals.values.all?(&:zero?) ? nil : totals
      end

      # Why the agent produced no usable report, or nil. A failed turn ends
      # with turn.failed, whose error says why (e.g. a model the account
      # can't use); a completed one with no text is reported as such.
      def self.error_message(jsonl)
        turn = turn_end(jsonl)
        return 'the stream has no turn.completed or turn.failed event' unless turn
        return failure_reason(jsonl) || 'the turn failed and gave no reason' if turn['type'] == 'turn.failed'

        'the agent gave no final message' unless final_response(jsonl)
      end

      # The reason a failed turn gives: its turn.failed error message, else
      # the last top-level error event's. nil if neither gives one.
      def self.failure_reason(jsonl)
        all = events(jsonl)
        failed = all.reverse_each.detect { |event| event['type'] == 'turn.failed' }
        error = failed['error'] if failed
        reason = error['message'] if error.is_a?(Hash)
        return reason.strip if reason.is_a?(String) && !reason.strip.empty?

        nonblank(all.filter_map { |event| event['message'] if event['type'] == 'error' }).last
      end
      private_class_method :failure_reason

      # Why an agent that exited nonzero failed. Codex explains a failed
      # turn in the stream, with stderr usually empty, so that comes first;
      # then stderr (e.g. for a bad flag or a crash).
      def self.exit_detail(stdout, stderr)
        failure_reason(stdout) || super
      end

      # Warnings about an agent, failed or not, each listing at most
      # MAX_LISTED_ERRORS distinct entries, each cut to MAX_ERROR_LENGTH
      # characters, so they stay short:
      # - the error items Codex reports without failing the turn (e.g.
      #   "Model metadata for `x` not found"), which may explain a weak
      #   report;
      # - the MCP tool calls that failed, such as those refused because
      #   codex exec never asks for approval ("MCP tool call requires
      #   approval, but approval policy is never"), whose results the
      #   report may lack.
      def self.warnings(jsonl)
        errors = nonblank(completed_items(jsonl, 'error').map { |item| item['message'] }).uniq
        calls = failed_calls(completed_items(jsonl, 'mcp_tool_call').select do |item|
          item['status'] == 'failed'
        end)
        warnings = []
        unless errors.empty?
          warnings << listing("Codex reported #{errors.size == 1 ? 'an error' : 'errors'}",
            errors)
        end
        unless calls.empty?
          warnings << listing("Codex MCP tool call#{'s' unless calls.size == 1} failed",
            calls)
        end
        warnings
      end

      # A warning: label, then entries, at most MAX_LISTED_ERRORS of them.
      def self.listing(label, entries)
        listed = entries.first(MAX_LISTED_ERRORS).map { |entry| shorten(entry, MAX_ERROR_LENGTH) }
        listed << "and #{entries.size - listed.size} more" if entries.size > listed.size
        "#{label}: #{listed.join('; ')}"
      end
      private_class_method :listing

      # Failed MCP tool calls as distinct "server.tool (reason)" entries.
      def self.failed_calls(calls)
        calls.map do |call|
          server, name = nonblank([call['server']]).first, nonblank([call['tool']]).first
          tool = name ? [server, name].compact.join('.') : 'unknown tool'
          error = call['error']
          reason = error['message'] if error.is_a?(Hash)
          reason.is_a?(String) && !reason.strip.empty? ? "#{tool} (#{reason.strip})" : tool
        end.uniq
      end
      private_class_method :failed_calls

      MAX_LISTED_ERRORS = 5
      MAX_ERROR_LENGTH = 200

      # The values that are nonblank strings, stripped.
      def self.nonblank(values)
        values.grep(String).map(&:strip).reject(&:empty?)
      end
      private_class_method :nonblank
    end
  end
end
