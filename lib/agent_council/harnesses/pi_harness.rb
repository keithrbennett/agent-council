# frozen_string_literal: true

# AgentCouncil::Harnesses::PiHarness — all knowledge specific to the pi
# coding-agent harness: how to invoke the pi CLI for one agent, with
# its tool allowlist and the shared read-only scaffolding, and how to read
# pi's JSONL event stream afterward.
#
# AgentCouncil is harness-agnostic and finds this module through
# AgentCouncil::Harnesses (lib/agent_council/harnesses.rb), by its NAME.

require 'json'
require_relative 'scaffold'

module AgentCouncil
  module Harnesses
    module PiHarness
      NAME = 'pi'

      # Analysis toolset (pi's built-in tool names): edit/write (and the
      # Windows-only powershell) are withheld. bash, a full shell, stays for
      # investigation (git log/status, dependency inspection, ...); only the
      # scaffolding text asks the model to use it read-only.
      TOOLS = 'read,grep,find,ls,bash'

      # Invocation for one agent. The substantive prompt is not part of argv;
      # it is piped to stdin (byte-identical for every analyst; the
      # consolidator gets its own).
      module_function def argv(provider, model)
        [
          NAME,
          '-p',               # non-interactive: process prompt and exit
          '--mode', 'json',   # JSONL event stream on stdout
          '--no-session',     # ephemeral: no session state between agents
          '--no-mcp',         # built-in MCP off: configured servers don't start
          '--tools', TOOLS,
          '--provider', provider,
          '--model', model,
          '--append-system-prompt', Harnesses.scaffold_text
        ]
      end

      # --- event stream reading ---

      # The assistant message from a single pi JSONL line, or nil if the line
      # is not an assistant message_end event.
      module_function def assistant_message_from_line(line)
        event =
          begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end

        return nil unless event.is_a?(Hash)
        return nil unless event['type'] == 'message_end'

        message = event['message']
        return nil unless message && message['role'] == 'assistant'

        message
      end

      # Assistant messages from all message_end events in a pi JSONL stream,
      # in order. Unparseable lines are skipped.
      module_function def assistant_messages(jsonl)
        jsonl.each_line.filter_map { |line| assistant_message_from_line(line) }
      end

      module_function def response_text(message)
        Array(message['content'])
          .select { |block| block['type'] == 'text' }
          .map { |block| block['text'] }
          .join("\n")
      end

      # The final assistant response: per pi's docs, message_end holds the
      # authoritative final message of each turn; the last assistant message_end
      # with actual text is the report (earlier ones belong to tool-use turns).
      module_function def final_response(jsonl)
        message = saved_message(assistant_messages(jsonl))
        message && response_text(message)
      end

      # The message final_response saves: the last one with text.
      module_function def saved_message(messages)
        messages.reverse_each.detect { |m| !response_text(m).empty? }
      end

      # Our usage keys, each mapped to pi's name for it. pi normalizes usage
      # across providers; its input excludes cache reads and writes.
      USAGE_KEYS = { 'input' => 'input', 'output' => 'output',
                     'cache_read' => 'cacheRead', 'cache_write' => 'cacheWrite' }.freeze

      # Token usage summed over all assistant messages (each is a separate
      # model request), as AgentCouncil expects it: integer 'input', 'output',
      # 'cache_read', and 'cache_write', plus 'cost' in US dollars when pi
      # priced the usage. nil when the stream reports no usage, as some
      # providers don't.
      module_function def usage(jsonl)
        usages = assistant_messages(jsonl).map { |m| m['usage'] }.grep(Hash)
        totals = USAGE_KEYS.transform_values { |key| usages.sum { |u| count(u[key]) } }
        return nil if totals.values.all?(&:zero?)

        cost = usages.sum { |u| u['cost'].is_a?(Hash) ? count(u['cost']['total']) : 0 }
        cost.positive? ? totals.merge('cost' => cost.round(6)) : totals
      end

      module_function def count(value)
        value.is_a?(Numeric) && value.positive? ? value : 0
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
      module_function def error_message(jsonl)
        messages = assistant_messages(jsonl)
        candidates = [messages.last, saved_message(messages)].compact.uniq
        message = candidates.detect { |m| m['errorMessage'].is_a?(String) && !m['errorMessage'].strip.empty? }
        return message['errorMessage'] if message

        message = candidates.detect { |m| UNUSABLE_STOP_REASONS.include?(m['stopReason']) }
        message && "stopped early (stopReason: #{message['stopReason']})"
      end

      # Why an agent that exited nonzero failed: pi explains it on stderr.
      module_function def exit_detail(_stdout, stderr)
        stderr.lines.map(&:strip).reject(&:empty?).first || 'no error output'
      end

      # Warnings about an agent that succeeded; pi's stream has none to give.
      module_function def warnings(_jsonl)
        []
      end
    end
  end
end
