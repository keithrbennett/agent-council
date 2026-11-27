# frozen_string_literal: true

# AgentCouncil::Harnesses::OpenCodeHarness — all knowledge specific to the
# OpenCode harness: how to invoke `opencode run` for one agent, with the
# shared scaffolding, and how to read its --format json event stream
# afterward.
#
# AgentCouncil is harness-agnostic and finds this class through
# AgentCouncil::Harnesses (lib/agent_council/harnesses.rb), by its NAME.
# Authentication and billing are left to OpenCode: an agent uses the
# credentials `opencode auth login` saved, as it would at the user's terminal.

require 'json'
require_relative 'harness'

module AgentCouncil
  module Harnesses
    class OpenCodeHarness < Harness
      NAME = 'opencode'

      # The scaffolding file env writes into the scratch dir: OpenCode reads
      # extra system-prompt text only from files its config's instructions
      # name.
      SCAFFOLD_FILE = 'agent-council-scaffold.md'

      # Invocation for one agent. The substantive prompt is not part of
      # argv; opencode run reads it from stdin. Unlike Claude Code's and
      # Codex's, the provider is passed: OpenCode takes provider/model.
      # --agent pins the agent whose edit permission env denies, whatever
      # default_agent a config names. No --auto: a tool call the user's
      # permissions set to "ask" is refused, since opencode run never asks.
      def self.argv(provider, model)
        [NAME, 'run', '--format', 'json', '--agent', AGENT, '--model', "#{provider}/#{model}"]
      end

      # The agent every OpenCode agent runs as.
      AGENT = 'build'

      # "provider / model" from an agent's command line: its --model gives
      # both, as provider/model (see argv). The model may itself contain a
      # "/", so only the first one separates them.
      def self.model_label(words)
        model = flag_value(words, '--model')
        model&.include?('/') ? model.split('/', 2).join(' / ') : super
      end

      # Variables for the agent's process, beside TMPDIR:
      # - OPENCODE_DB, a database in the scratch dir, so the session is
      #   deleted with it when the agent finishes (the other harnesses
      #   save none), and concurrent agents don't share one database.
      # - OPENCODE_CONFIG_CONTENT, which OpenCode merges over the user's and
      #   the project's config (replacing a user's own value):
      #   - the scaffolding, as an instructions file;
      #   - edit permission denied, globally and for AGENT, withholding the
      #     file-editing tools by default, as the other harnesses withhold
      #     theirs (a config can still allow them; bash stays either way);
      #   - the scratch dir allowed as an external directory for AGENT, so
      #     its own tools can read what it puts in $TMPDIR (per agent, since
      #     a global map would replace a user's scalar value);
      #   - experimental.continue_loop_on_deny, so a refused tool call
      #     doesn't end the session;
      #   - the title agent disabled, since its request isn't in the stream
      #     (so not in usage);
      #   - snapshots off, so the project's files aren't copied into
      #     OpenCode's data dir.
      # Writes the scaffolding file into scratch_dir.
      def self.env(scratch_dir)
        scaffold = File.join(scratch_dir, SCAFFOLD_FILE)
        File.write(scaffold, Harnesses.scaffold_text)
        deny = { 'edit' => 'deny' }
        scratch = { 'external_directory' => { File.join(scratch_dir, '*') => 'allow' } }
        config = { 'instructions' => [scaffold], 'permission' => deny,
                   'agent'        => { AGENT   => { 'permission' => deny.merge(scratch) },
                                       'title' => { 'disable' => true } },
                   'snapshot'     => false, 'experimental' => { 'continue_loop_on_deny' => true } }
        { 'OPENCODE_DB'             => File.join(scratch_dir, 'opencode.db'),
          'OPENCODE_CONFIG_CONTENT' => JSON.generate(config) }
      end

      # --- event stream reading ---

      # The parts of the events of the given type, in order.
      def self.parts(jsonl, type)
        events(jsonl).filter_map do |event|
          part = event['part'] if event['type'] == type
          part if part.is_a?(Hash)
        end
      end
      private_class_method :parts

      # The agent's model requests: one step_finish part each, carrying its
      # tokens and cost.
      def self.assistant_messages(jsonl)
        parts(jsonl, 'step_finish')
      end

      # The final response: the text of the last assistant message with any,
      # its text parts joined, for an agent that hit no error. Earlier
      # messages narrate its tool use. Synthetic parts, which OpenCode
      # writes itself (e.g. after compacting the session), are skipped.
      def self.final_response(jsonl)
        return nil if failure_reason(jsonl)

        texts = report_texts(jsonl)
        return nil if texts.empty?

        last_id = texts.last['messageID']
        texts.select { |part| part['messageID'] == last_id }.map { |part| part['text'] }.join("\n")
      end

      # The nonblank text parts, less those OpenCode wrote itself
      # (synthetic) or marked ignored.
      def self.report_texts(jsonl)
        parts(jsonl, 'text').select do |part|
          nonblank_text(part['text']) && !part['synthetic'] && !part['ignored']
        end
      end
      private_class_method :report_texts

      # The ID of the message final_response takes its text from, or nil.
      def self.final_response_message_id(jsonl)
        report_texts(jsonl).last&.fetch('messageID', nil)
      end
      private_class_method :final_response_message_id

      # Token usage as AgentCouncil expects it (see Harness), summed over
      # the step_finish parts. OpenCode's input excludes cached input;
      # reasoning tokens, counted apart, are added to output. 'cost' is
      # OpenCode's own estimate, from its model catalog.
      # nil when the stream reports no usage.
      def self.usage(jsonl)
        steps = assistant_messages(jsonl)
        tokens = steps.map { |part| part['tokens'] }.grep(Hash)
        caches = tokens.map { |t| t['cache'] }.grep(Hash)
        totals = { 'input'       => tokens.sum { |t| count(t['input']) },
                   'output'      => tokens.sum { |t| count(t['output']) + count(t['reasoning']) },
                   'cache_read'  => caches.sum { |c| count(c['read']) },
                   'cache_write' => caches.sum { |c| count(c['write']) } }
        usage_result(totals, steps.sum { |part| count(part['cost']) })
      end

      # Finish reasons meaning a model request was cut off or failed, not
      # completed (the AI SDK's, which OpenCode reports).
      UNUSABLE_FINISH_REASONS = %w[length content-filter error].freeze

      # Why the agent produced no usable report, or nil. Older OpenCode
      # versions exit 0 after an error (e.g. an unavailable model), so an
      # error event fails the agent whatever the exit status; and a request
      # that finished for an UNUSABLE_FINISH_REASONS reason leaves a
      # partial report if it was the last one or the report's message,
      # even if a later request (with no text) completed. A stream with no
      # text is left to run_agent, which says what it has.
      def self.error_message(jsonl)
        failure = failure_reason(jsonl)
        return failure if failure

        steps = assistant_messages(jsonl)
        report_id = final_response_message_id(jsonl)
        reason = [steps.last, steps.reverse_each.detect { |s| report_id && s['messageID'] == report_id }]
          .compact.map { |s| s['reason'] }.find { |r| UNUSABLE_FINISH_REASONS.include?(r) }
        return "stopped early (reason: #{reason})" if reason

        stopped_at_tool_calls(steps, jsonl)
      end

      # A session whose last request ended in tool calls, with nothing
      # after, was stopped (exit 0, no error event), its last text being
      # the model's lead-in to the call: as a rejected "ask" call would
      # stop it without the continue_loop_on_deny env sets. nil otherwise.
      # Only the last request's rejected calls are named: an earlier one
      # the agent went on from didn't stop it.
      def self.stopped_at_tool_calls(steps, jsonl)
        return nil unless steps.last&.fetch('reason', nil) == 'tool-calls'

        last_id = steps.last['messageID']
        tools = last_id ? rejected_tools(jsonl, last_id) : []
        return 'stopped early (reason: tool-calls)' if tools.empty?

        "stopped when OpenCode refused a tool call its permissions set to ask (#{tools.uniq.join(', ')})"
      end
      private_class_method :stopped_at_tool_calls

      # The error text OpenCode gives a tool call whose permission it rejected.
      REJECTION_PREFIX = 'The user rejected permission'

      # The tools of the tool calls OpenCode rejected for want of permission,
      # in order, only those of the message with the given ID if one is
      # given.
      def self.rejected_tools(jsonl, message_id = nil)
        parts(jsonl, 'tool_use').filter_map do |part|
          state = part['state'].is_a?(Hash) ? part['state'] : {}
          next unless state['status'] == 'error' && state['error'].to_s.start_with?(REJECTION_PREFIX)
          next if message_id && part['messageID'] != message_id

          part['tool'].is_a?(String) ? part['tool'] : 'unknown tool'
        end
      end
      private_class_method :rejected_tools

      # The last error event's message, else its error's name. nil if the
      # stream has no error event.
      def self.failure_reason(jsonl)
        event = last_event(jsonl, 'error')
        return nil unless event

        error = event['error'].is_a?(Hash) ? event['error'] : {}
        data = error['data'].is_a?(Hash) ? error['data'] : {}
        nonblank_strings([data['message'], error['name']]).first ||
          'an error event gave no reason'
      end
      private_class_method :failure_reason

      # Why an agent that exited nonzero failed: the stream's error event
      # if there is one, else stderr (e.g. for a bad flag).
      def self.exit_detail(stdout, stderr)
        failure_reason(stdout) || super
      end

      # Warnings about an agent: one for the tool calls OpenCode rejected
      # for want of permission (set to "ask", which opencode run can't
      # ask), as the other harnesses report refusals, with their count and
      # tools. A call a deny rule blocks has another error text, and like
      # other failed tool calls is an ordinary tool error the agent sees
      # and goes on from.
      def self.warnings(jsonl)
        tools = rejected_tools(jsonl)
        return [] if tools.empty?

        calls = tools.size == 1 ? 'a tool call' : "#{tools.size} tool calls"
        ["OpenCode refused #{calls} for want of permission (#{tools.uniq.join(', ')})"]
      end
    end
  end
end
