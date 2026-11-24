# frozen_string_literal: true

# AgentCouncil::Harnesses — the harnesses agents can run under, by the name
# a config entry gives in its 'harness' key. Each is a subclass of
# Harness (harnesses/harness.rb), which documents what AgentCouncil calls
# on one and gives defaults; AgentCouncil looks one up per agent with
# class_for. What every harness's agents are told, the read-only
# scaffolding, is in harnesses/scaffold.rb.

require_relative 'harnesses/harness'
require_relative 'harnesses/pi_harness'
require_relative 'harnesses/claude_code_harness'
require_relative 'harnesses/codex_harness'
require_relative 'harnesses/opencode_harness'

module AgentCouncil
  module Harnesses
    BY_NAME = [PiHarness, ClaudeCodeHarness, CodexHarness, OpenCodeHarness].to_h do |harness|
      [harness::NAME, harness]
    end.freeze

    # The harness of a report or run.json entry without a 'harness' key:
    # agent-council writes one in each, so these are hand-edited or older
    # than 0.1.0, when every agent ran under pi.
    # A config entry must name its harness (see AgentCouncil.entry_error).
    DEFAULT_NAME = PiHarness::NAME

    # The harness name a config entry, report front matter, or run.json
    # entry gives, or DEFAULT_NAME when it gives no string one. Config
    # entries are validated first (see AgentCouncil.entry_error), so only
    # unvalidated ones, such as a hand-edited report's front matter or an
    # older run's, are read as pi.
    module_function def name_of(entry)
      harness = entry['harness'] if entry.is_a?(Hash)
      harness.is_a?(String) ? harness : DEFAULT_NAME
    end

    # The harness class for an entry; KeyError for an unknown name, which
    # config validation rules out before any agent runs.
    module_function def class_for(entry)
      BY_NAME.fetch(name_of(entry))
    end
  end
end
