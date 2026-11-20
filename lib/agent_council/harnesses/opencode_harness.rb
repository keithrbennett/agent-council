# frozen_string_literal: true

# AgentCouncil::Harnesses::OpenCodeHarness — all knowledge specific to the
# OpenCode harness: how to invoke `opencode run` for one agent, with the
# shared scaffolding, and how to read its --format json event stream
# afterward.
#
# AgentCouncil is harness-agnostic and finds this module through
# AgentCouncil::Harnesses (lib/agent_council/harnesses.rb), by its NAME.
# Authentication and billing are left to OpenCode: an agent uses the
# credentials `opencode auth login` saved, as it would at the user's terminal.

require 'json'
require_relative 'scaffold'

module AgentCouncil
  module Harnesses
    module OpenCodeHarness
      NAME = 'opencode'

      # The scaffolding file env writes into the scratch dir: OpenCode reads
      # extra system-prompt text only from files its config's instructions
      # name.
      SCAFFOLD_FILE = 'agent-council-scaffold.md'

      # Invocation for one agent. The substantive prompt is not part of
      # argv; opencode run reads it from stdin. Unlike Claude Code's and
      # Codex's, the provider is passed: OpenCode takes provider/model.
      #
      # --agent pins OpenCode's default agent, build, whose edit permission
      # env denies (a default_agent in the user's or the project's config
      # could name one that allows editing). No --auto: a tool call the
      # user's permissions set to "ask" is rejected, since opencode run
      # never asks; env keeps the rejection from ending the session.
      module_function def argv(provider, model)
        [NAME, 'run', '--format', 'json', '--agent', AGENT, '--model', "#{provider}/#{model}"]
      end

      # The agent every OpenCode agent runs as.
      AGENT = 'build'

      # The agents whose edit permission env denies one by one, each with
      # its own mode: the agent agents run as, and the built-in subagents
      # its task tool starts. A per-agent permission comes after the global
      # one, so the user's or the project's config could otherwise allow
      # editing for one. Each keeps its mode, and AGENT is also kept
      # enabled: had the config disabled AGENT or made it a subagent,
      # --agent would fall back to the default agent, whose permission env
      # doesn't deny. A subagent the user or the project disabled stays
      # disabled.
      DENIED_AGENTS = { AGENT => 'primary', 'general' => 'subagent', 'explore' => 'subagent' }.freeze

      # Variables for the agent's process, beside TMPDIR:
      # - OPENCODE_DB, a database in the scratch dir, so the session is
      #   discarded with it rather than added to the user's history, and
      #   concurrent agents don't share one database. Credentials are kept
      #   elsewhere (auth.json), so they still apply.
      # - OPENCODE_CONFIG_CONTENT, which OpenCode merges over the user's and
      #   the project's config (an instructions list is appended to
      #   theirs): the scaffolding, as an instructions file, and edit
      #   permission denied, globally and for DENIED_AGENTS, which
      #   withholds OpenCode's file-editing tools, as the other harnesses
      #   withhold theirs. bash stays; only the scaffolding asks the model
      #   to use it read-only. AGENT is repeated under the legacy mode key,
      #   which OpenCode merges after this config, so a mode entry can't
      #   allow editing for it. The subagents aren't: a mode entry makes an
      #   agent primary, which would hide them from the task tool. So a
      #   user's or project's mode entry for one can allow it editing,
      #   though the task tool no longer offers it (a model can still name
      #   it), like a custom subagent that allows editing. The hidden
      #   title agent is disabled: it would make a request of its own,
      #   absent from the stream (so from usage), to the provider's small
      #   model, for a title nobody sees. experimental.continue_loop_on_deny
      #   lets the agent go on after a tool call opencode run rejects (one
      #   set to "ask", as OpenCode's defaults set external_directory,
      #   doom_loop, and reading .env files), as the other harnesses'
      #   agents go on after a refusal; otherwise the rejection ends the
      #   session, leaving the model's lead-in as its last text. Snapshots are
      #   turned off: OpenCode would otherwise copy the project's untracked
      #   files into a git store in its data dir, kept after the run. A
      #   user's own OPENCODE_CONFIG_CONTENT is replaced.
      # An inherited OPENCODE_PERMISSION is left alone: OpenCode applies it
      # over the global permission, but the per-agent denials still win, so
      # its other rules (e.g. bash: deny) apply as they would interactively.
      # Writes the scaffolding file into scratch_dir.
      module_function def env(scratch_dir)
        scaffold = File.join(scratch_dir, SCAFFOLD_FILE)
        File.write(scaffold, Harnesses.scaffold_text)
        deny = { 'edit' => 'deny' }
        agents = DENIED_AGENTS.to_h { |agent, mode| [agent, { 'mode' => mode, 'permission' => deny }] }
        agents[AGENT]['disable'] = false
        agents['title'] = { 'disable' => true }
        config = { 'instructions' => [scaffold], 'permission' => deny, 'agent' => agents,
                   'mode' => agents.slice(AGENT), 'snapshot' => false,
                   'experimental' => { 'continue_loop_on_deny' => true } }
        { 'OPENCODE_DB'             => File.join(scratch_dir, 'opencode.db'),
          'OPENCODE_CONFIG_CONTENT' => JSON.generate(config) }
      end

      # --- event stream reading ---

      # The events of a --format json stream, in order. Unparseable lines and
      # non-objects are skipped.
      module_function def events(jsonl)
        jsonl.each_line.filter_map do |line|
          event =
            begin
              JSON.parse(line)
            rescue JSON::ParserError
              nil
            end
          event if event.is_a?(Hash)
        end
      end

      # The parts of the events of the given type, in order.
      module_function def parts(jsonl, type)
        events(jsonl).filter_map do |event|
          part = event['part'] if event['type'] == type
          part if part.is_a?(Hash)
        end
      end

      # The agent's model requests: one step_finish part each, carrying its
      # tokens and cost.
      module_function def assistant_messages(jsonl)
        parts(jsonl, 'step_finish')
      end

      # The final response: the text of the last assistant message with any,
      # its text parts joined, for an agent that hit no error. Earlier
      # messages narrate its tool use. Synthetic parts, which OpenCode
      # writes itself (e.g. after compacting the session), are skipped.
      module_function def final_response(jsonl)
        return nil if failure_reason(jsonl)

        texts = report_texts(jsonl)
        return nil if texts.empty?

        last_id = texts.last['messageID']
        texts.select { |part| part['messageID'] == last_id }.map { |part| part['text'] }.join("\n")
      end

      # The nonblank, non-synthetic text parts.
      module_function def report_texts(jsonl)
        parts(jsonl, 'text').select do |part|
          part['text'].is_a?(String) && !part['text'].strip.empty? && !part['synthetic']
        end
      end

      # The ID of the message final_response takes its text from, or nil.
      module_function def final_response_message_id(jsonl)
        report_texts(jsonl).last&.fetch('messageID', nil)
      end

      # Token usage as AgentCouncil expects it (see Harnesses), summed over
      # the step_finish parts. OpenCode's input excludes cached input;
      # reasoning tokens, counted apart, are added to output. 'cost' is
      # OpenCode's own estimate, from its model catalog.
      # nil when the stream reports no usage.
      module_function def usage(jsonl)
        steps = assistant_messages(jsonl)
        tokens = steps.map { |part| part['tokens'] }.grep(Hash)
        caches = tokens.map { |t| t['cache'] }.grep(Hash)
        totals = { 'input'       => tokens.sum { |t| count(t['input']) },
                   'output'      => tokens.sum { |t| count(t['output']) + count(t['reasoning']) },
                   'cache_read'  => caches.sum { |c| count(c['read']) },
                   'cache_write' => caches.sum { |c| count(c['write']) } }
        return nil if totals.values.all?(&:zero?)

        cost = steps.sum { |part| count(part['cost']) }
        cost.positive? ? totals.merge('cost' => cost.round(6)) : totals
      end

      module_function def count(value)
        value.is_a?(Numeric) && value.positive? ? value : 0
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
      module_function def error_message(jsonl)
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
      module_function def stopped_at_tool_calls(steps, jsonl)
        return nil unless steps.last&.fetch('reason', nil) == 'tool-calls'

        tools = rejected_tools(jsonl)
        return 'stopped early (reason: tool-calls)' if tools.empty?

        "stopped when OpenCode refused a tool call its permissions set to ask (#{tools.uniq.join(', ')})"
      end

      # The error text OpenCode gives a tool call whose permission it rejected.
      REJECTION_PREFIX = 'The user rejected permission'

      # The tools of the tool calls OpenCode rejected for want of permission,
      # in order.
      module_function def rejected_tools(jsonl)
        parts(jsonl, 'tool_use').filter_map do |part|
          state = part['state'].is_a?(Hash) ? part['state'] : {}
          next unless state['status'] == 'error' && state['error'].to_s.start_with?(REJECTION_PREFIX)

          part['tool'].is_a?(String) ? part['tool'] : 'unknown tool'
        end
      end

      # The last error event's message, else its error's name. nil if the
      # stream has no error event.
      module_function def failure_reason(jsonl)
        event = events(jsonl).reverse_each.detect { |e| e['type'] == 'error' }
        return nil unless event

        error = event['error'].is_a?(Hash) ? event['error'] : {}
        data = error['data'].is_a?(Hash) ? error['data'] : {}
        [data['message'], error['name']].grep(String).map(&:strip).reject(&:empty?).first ||
          'an error event gave no reason'
      end

      # Why an agent that exited nonzero failed: the stream's error event
      # if there is one, else stderr (e.g. for a bad flag).
      module_function def exit_detail(stdout, stderr)
        failure_reason(stdout) || stderr.lines.map(&:strip).reject(&:empty?).first || 'no error output'
      end

      # Warnings about an agent: one per tool call OpenCode rejected for
      # want of permission (set to "ask", which opencode run can't ask),
      # as the other harnesses report refusals. A call a deny rule blocks
      # has another error text, and like other failed tool calls is an
      # ordinary tool error the agent sees and goes on from.
      module_function def warnings(jsonl)
        rejected_tools(jsonl).map { |tool| "OpenCode refused a #{tool} call for want of permission" }
      end
    end
  end
end
