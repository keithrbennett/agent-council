# frozen_string_literal: true

# AgentCouncil::Harnesses::PiHarness — all knowledge specific to the pi
# coding-agent harness: how to invoke the pi CLI for one agent, with
# its tool allowlist and the shared read-only scaffolding, and how to read
# pi's JSONL event stream afterward.
#
# AgentCouncil is harness-agnostic and finds this class through
# AgentCouncil::Harnesses (lib/agent_council/harnesses.rb), by its NAME.

require_relative 'harness'

module AgentCouncil
  module Harnesses
    # env, exit_detail, and warnings are Harness's defaults: pi needs no
    # variables beyond TMPDIR, explains a nonzero exit on stderr, and gives
    # no warnings, since a failed tool call, MCP calls included, is an
    # ordinary tool error the agent sees, not a refusal (DESIGN.md §11).
    class PiHarness < Harness
      NAME = 'pi'

      # Analysis toolset (pi's built-in tool names): edit/write (and the
      # Windows-only powershell) are withheld. bash, a full shell, stays for
      # investigation (git log/status, dependency inspection, ...); only the
      # scaffolding text asks the model to use it read-only. The rest give
      # agents the MCP tools pi gives an interactive session, however a
      # server exposes them: codemode for the default exposure (a server's
      # tools are called from a codemode script, which reaches only the
      # tools listed here), mcp__* for servers with direct exposure,
      # tool_search for servers with deferred exposure (it loads only MCP
      # tools, not withheld built-in ones), and pi's MCP resource tools,
      # which --tools would drop once it names an mcp__ entry.
      TOOLS = %w[read grep find ls bash
        codemode mcp__* tool_search
        list_mcp_resources list_mcp_resource_templates read_mcp_resource].join(',')

      # Invocation for one agent. The substantive prompt is not part of argv;
      # it is piped to stdin (byte-identical for every analyst; the
      # consolidator gets its own).
      def self.argv(provider, model)
        [
          NAME,
          '-p',               # non-interactive: process prompt and exit
          '--mode', 'json',   # JSONL event stream on stdout
          '--no-session',     # ephemeral: no session state between agents
          '--tools', TOOLS,
          '--provider', provider,
          '--model', model,
          '--append-system-prompt', Harnesses.scaffold_text
        ]
      end

      # --- event stream reading ---

      # The messages of a pi JSONL stream's message_end events with one of
      # the given roles, in order.
      def self.messages_with_role(jsonl, *roles)
        events(jsonl).filter_map do |event|
          message = event['message'] if event['type'] == 'message_end'
          message if message.is_a?(Hash) && roles.include?(message['role'])
        end
      end
      private_class_method :messages_with_role

      # Assistant messages from all message_end events in a pi JSONL stream,
      # in order.
      def self.assistant_messages(jsonl)
        messages_with_role(jsonl, 'assistant')
      end

      def self.response_text(message)
        Array(message['content'])
          .select { |block| block['type'] == 'text' }
          .map { |block| block['text'] }
          .join("\n")
      end
      private_class_method :response_text

      # The final assistant response: per pi's docs, message_end holds the
      # authoritative final message of each turn; the last assistant message_end
      # with actual text is the report (earlier ones belong to tool-use turns).
      def self.final_response(jsonl)
        message = saved_message(assistant_messages(jsonl))
        message && response_text(message)
      end

      # The message final_response saves: the last one with text.
      def self.saved_message(messages)
        messages.reverse_each.detect { |m| !response_text(m).empty? }
      end
      private_class_method :saved_message

      # Our usage keys, each mapped to pi's name for it. pi normalizes usage
      # across providers; its input excludes cache reads and writes.
      USAGE_KEYS = { 'input' => 'input', 'output' => 'output',
                     'cache_read' => 'cacheRead', 'cache_write' => 'cacheWrite' }.freeze

      # Token usage summed over all assistant messages (each is a separate
      # model request) and tool results, as AgentCouncil expects it: integer
      # 'input', 'output', 'cache_read', and 'cache_write', plus 'cost' in US
      # dollars when pi priced the usage. A tool result has usage when the
      # tool called a model itself, e.g. a codemode script's models.classify
      # call. nil when the stream reports no usage, as some providers don't.
      def self.usage(jsonl)
        usages = messages_with_role(jsonl, 'assistant', 'toolResult').map { |m| m['usage'] }.grep(Hash)
        totals = USAGE_KEYS.transform_values { |key| usages.sum { |u| count(u[key]) } }
        usage_result(totals, usages.sum { |u| u['cost'].is_a?(Hash) ? count(u['cost']['total']) : 0 })
      end

      # Stop reasons meaning a message was cut off, cancelled, or failed, not
      # completed. error normally comes with an errorMessage, which is reported
      # instead; this catches one that is missing or blank.
      UNUSABLE_STOP_REASONS = %w[length aborted error].freeze

      # Why the agent produced no usable report, or nil. Pi exits 0 even when the
      # provider rejects the request or the output hits its token limit, so this
      # is how such failures are surfaced. Two messages are checked: the final
      # one (an error in an earlier turn that a later turn recovered from is not
      # a failure, while an error on the last turn means any earlier text is a
      # partial fragment) and the one final_response would save (a cut-off
      # message must not be saved just because a text-less message followed it).
      # A non-blank string errorMessage on either wins over a cut-off stopReason on
      # the other, since it says more about what went wrong.
      def self.error_message(jsonl)
        messages = assistant_messages(jsonl)
        candidates = [messages.last, saved_message(messages)].compact.uniq
        message = candidates.detect { |m| nonblank_text(m['errorMessage']) }
        return message['errorMessage'] if message

        message = candidates.detect { |m| UNUSABLE_STOP_REASONS.include?(m['stopReason']) }
        message && "stopped early (stopReason: #{message['stopReason']})"
      end
    end
  end
end
