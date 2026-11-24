# frozen_string_literal: true

# AgentCouncil::Harnesses::Harness — the base class of every harness: the
# interface agent-council and agent-council-ps call, with defaults a
# harness inherits unless it overrides them. A harness is a subclass used
# as is, through class methods; it's never instantiated. AgentCouncil
# looks one up per agent through AgentCouncil::Harnesses
# (lib/agent_council/harnesses.rb).
#
# Each subclass defines NAME, both the config value and the executable
# argv runs, which the startup check looks for on PATH. It also goes into
# report filenames unsanitized, so it must be one AgentCouncil.sanitize
# leaves unchanged (the specs check this). The scaffolding sends agents to
# $TMPDIR, which run_agent sets to the scratch dir, so a harness must pass
# TMPDIR through to its tools.
#
# A subclass defines argv, usage, final_response, assistant_messages, and
# error_message (here they raise NoMethodError); the rest have defaults
# here. Helpers are private class methods.

require 'json'
require_relative 'scaffold'

module AgentCouncil
  module Harnesses
    class Harness
      # exit_detail's reason when the agent left none.
      NO_ERROR_OUTPUT = 'no error output'

      # The command line for one agent, starting with NAME. The prompt
      # isn't in it; run_agent pipes it to stdin.
      def self.argv(_provider, _model)
        raise_undefined(:argv)
      end

      # The variables the agent's process needs beyond TMPDIR, which
      # run_agent sets: String names, each with a String value; by default
      # none. It may write files into scratch_dir, which is removed after the
      # agent finishes.
      def self.env(_scratch_dir)
        {}
      end

      # The agent's token usage as AgentCouncil records it, summed over all
      # its requests: integer 'input' (excluding cached input), 'output',
      # 'cache_read', and 'cache_write', plus 'cost' in US dollars when the
      # harness priced the usage; or nil when the harness reports no usage.
      def self.usage(_stdout)
        raise_undefined(:usage)
      end

      # The agent's report, the text of its final response, or nil if
      # there's none.
      def self.final_response(_stdout)
        raise_undefined(:final_response)
      end

      # The agent's assistant messages, in order (empty for none), which
      # says whether the stream had any when final_response finds no report.
      def self.assistant_messages(_stdout)
        raise_undefined(:assistant_messages)
      end

      # Why an agent that exited 0 produced no usable report, or nil.
      def self.error_message(_stdout)
        raise_undefined(:error_message)
      end

      # Why an agent that exited nonzero failed; by default, the first
      # nonblank line of its stderr, or NO_ERROR_OUTPUT. The caller puts it,
      # and error_message's reason, on one line cut to 300 characters
      # (AgentCouncil.failure_reason), so a harness returns the reason whole.
      def self.exit_detail(_stdout, stderr)
        first_line(stderr) || NO_ERROR_OUTPUT
      end

      # Messages (empty for none, the default) about an agent, failed or
      # not; the caller prints and records them all, so a harness keeps them
      # few and short.
      def self.warnings(_stdout)
        []
      end

      # "provider / model" from an agent's command line (its words, as
      # agent-council-ps reads them), as far as it shows them: by default,
      # its --provider and --model values, either of which may be missing
      # ("" if both are). The specs check that it reads back what argv
      # gives.
      def self.model_label(words)
        [flag_value(words, '--provider'), flag_value(words, '--model')].compact.join(' / ')
      end

      # Raised by the methods above that a subclass must define. A
      # NoMethodError, as calling a missing method would raise, so
      # run_agent's rescue fails only that agent (NotImplementedError, a
      # ScriptError, would escape it and stop the run).
      def self.raise_undefined(name)
        raise NoMethodError.new("#{self} must define #{name}", name)
      end
      private_class_method :raise_undefined

      # --- helpers for subclasses ---

      # The word after the first flag in words, or nil.
      def self.flag_value(words, flag)
        index = words.index(flag)
        words[index + 1] if index
      end
      private_class_method :flag_value

      # The events of a JSONL stream, in order. Unparseable lines and
      # non-objects are skipped.
      def self.events(jsonl)
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
      private_class_method :events

      # A token count or cost from a stream: value if it's a positive
      # number, else 0.
      def self.count(value)
        value.is_a?(Numeric) && value.positive? ? value : 0
      end
      private_class_method :count

      # text, cut to max characters with "..." if longer.
      def self.shorten(text, max)
        text.length > max ? "#{text[0, max]}..." : text
      end
      private_class_method :shorten

      # The first nonblank line of text, stripped, or nil.
      def self.first_line(text)
        text.lines.map(&:strip).reject(&:empty?).first
      end
      private_class_method :first_line
    end
  end
end
