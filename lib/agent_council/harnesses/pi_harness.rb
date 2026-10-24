# frozen_string_literal: true

# AgentCouncil::Harnesses::PiHarness — all knowledge specific to the pi
# coding-agent harness: how to invoke the pi CLI for one model run, the
# tool allowlist and read-only scaffolding delivered with it, and how to
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

      # Analysis toolset (pi's built-in tool names): edit/write (and the
      # Windows-only powershell) are withheld. bash, a full shell, stays for
      # investigation (git log/status, dependency inspection, ...); only the
      # scaffolding text asks the model to use it read-only.
      TOOLS = 'read,grep,find,ls,bash'

      # Invocation for one model run. The substantive prompt is not part of argv;
      # it is piped to stdin (byte-identical for every analyst; the
      # consolidator gets its own).
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
          You are one of the independent agents agent-council runs on this
          repository. This is a strictly read-only analysis task.

          Rules:
          - Do not modify, create, rename, or delete any project source or
            configuration file. Do not change git state, install or remove
            software, modify user or system configuration, or start persistent
            services.
          - Do not run test suites, builds, coverage tools, application servers,
            or database tasks unless the user's prompt explicitly permits it:
            other agents may be running concurrently and such commands can collide
            through shared state (databases, ports, Docker, fixed temp paths).
            Where the prompt permits them, direct their temporary output to the
            scratch directory below, and still skip any that need shared
            services (databases, servers, fixed ports, Docker). Otherwise, if
            running such a command would materially improve your analysis,
            describe what you would run and why instead of running it.
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
        message = saved_message(assistant_messages(jsonl))
        message && response_text(message)
      end

      # The message final_response saves: the last one with text.
      module_function def saved_message(messages)
        messages.reverse_each.detect { |m| !response_text(m).empty? }
      end

      # Stop reasons meaning a message was cut off, cancelled or failed, not
      # completed. error normally comes with an errorMessage, which is reported
      # instead; this catches one that is missing or blank.
      UNUSABLE_STOP_REASONS = %w[length aborted error].freeze

      # Why the run produced no usable report, or nil. Pi exits 0 even when the
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
    end
  end
end
