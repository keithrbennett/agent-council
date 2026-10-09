# frozen_string_literal: true

# AgentCouncil::Harnesses::PiHarness — all knowledge specific to the pi
# coding-agent harness: how to invoke the pi CLI for one model run, the
# read-only tool policy and scaffolding delivered with it, and how to
# read pi's JSONL event stream afterward.
#
# AgentCouncil is harness-agnostic and refers to this module only via
# AgentCouncil::HARNESS. A second harness (claude, codex, ...) would be
# another module under AgentCouncil::Harnesses shaped like this one —
# this is deliberately a plain namespace, not an adapter framework.

require 'json'

module AgentCouncil
  module Harnesses
    module PiHarness
      NAME = 'pi'

      # Read-only analysis toolset (pi's built-in tool names): edit/write are
      # withheld at the harness level. bash stays available for read-only
      # investigation (git log/status, dependency inspection, ...); the
      # scaffolding text constrains its use.
      TOOLS = 'read,grep,find,ls,bash'

      # Invocation for one model run. The substantive prompt is not part of argv;
      # it is piped to stdin, byte-identical for every agent.
      module_function def argv(provider, model, scratch_dir)
        [
          NAME,
          '-p',               # non-interactive: process prompt and exit
          '--mode', 'json',   # JSONL event stream on stdout
          '--no-session',     # ephemeral: no session state between runs
          '--tools', TOOLS,
          '--provider', provider,
          '--model', model,
          '--append-system-prompt', scaffold_text(scratch_dir)
        ]
      end

      # Scaffolding appended to pi's system prompt. Identical for every agent
      # except the scratch dir path.
      module_function def scaffold_text(scratch_dir)
        <<~TEXT
          You are one of several independent agents analyzing the same repository
          with the same prompt. This is a strictly read-only analysis task.

          Rules:
          - Do not modify, create, rename, or delete any project source or
            configuration file. Do not change git state, install or remove
            software, modify user or system configuration, or start persistent
            services.
          - Do not run test suites, builds, coverage tools, application servers,
            or database tasks: other analysts are running concurrently and such
            commands can collide through shared state (databases, ports, Docker,
            fixed temp paths). If running such a command would materially improve
            your analysis, describe what you would run and why instead of running
            it.
          - You may run clearly read-only commands: reading, searching and
            listing files; inspecting git history and status; inspecting
            dependency and configuration information.
          - If you need scratch space for temporary artifacts, use this
            disposable directory that is unique to your run: #{scratch_dir}
          - Deliver your complete analysis as your final message text. Do not
            write the report to a file; the orchestrator captures your final
            message directly.
        TEXT
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
        message = assistant_messages(jsonl).reverse_each.detect do |m|
          !response_text(m).empty?
        end
        message && response_text(message)
      end

      # Provider-reported error on the final assistant message, if any. Pi exits 0
      # even when the provider rejects the request, so this is how such failures
      # are surfaced. Only the final message counts: an error in an earlier turn
      # that a later turn recovered from is not a failure, while an error on the
      # last turn means any earlier text is a partial fragment, not a report.
      module_function def error_message(jsonl)
        assistant_messages(jsonl).last&.fetch('errorMessage', nil)
      end
    end
  end
end
