# frozen_string_literal: true

# AgentCouncil::Harnesses — the harnesses agents can run under, by the name
# a config entry gives in its 'harness' key. What they share, the read-only
# scaffolding, is in harnesses/scaffold.rb.
#
# Each harness is a plain module shaped like PiHarness (NAME,
# DEFAULT_PROVIDER, argv, usage, error_message, exit_detail, warnings,
# final_response, assistant_messages), not an adapter framework;
# AgentCouncil looks one up per agent with module_for. NAME is both the
# config value and the executable argv runs, which the startup check looks
# for on PATH. It also goes into report filenames unsanitized,
# so it must be one AgentCouncil.sanitize leaves unchanged (the specs
# check this).
#
# DEFAULT_PROVIDER is the provider recorded for an entry that gives none,
# or nil if every entry must give one (see with_defaults). exit_detail
# (stdout, stderr) says why a run that exited nonzero failed; the caller
# puts it, and error_message's reason, on one line cut to 300
# characters (AgentCouncil.failure_reason), so a harness returns the
# reason whole. warnings returns an Array of messages (empty for none)
# about a run, failed or not; the caller prints and records them all, so a
# harness keeps them few and short.
#
# usage returns the run's token usage as AgentCouncil records it, summed
# over the whole run: integer 'input' (excluding cached input), 'output',
# 'cache_read', and 'cache_write', plus 'cost' in US dollars when the
# harness priced the run; or nil when the harness reports no usage.

require_relative 'harnesses/pi_harness'
require_relative 'harnesses/claude_code_harness'

module AgentCouncil
  module Harnesses
    BY_NAME = [PiHarness, ClaudeCodeHarness].to_h { |harness| [harness::NAME, harness] }.freeze

    # The harness of an entry without a 'harness' key: config entries that
    # don't name one, and reports and run.json entries from before there
    # was a choice.
    DEFAULT_NAME = PiHarness::NAME

    # The harness name a config entry, report front matter, or run.json
    # entry gives, or DEFAULT_NAME when it gives no string one. Config
    # entries are validated against the raw value first (see
    # AgentCouncil.entry_error), so only unvalidated front matter, such as
    # a hand-edited report's, has a non-string value read as pi.
    module_function def name_of(entry)
      harness = entry['harness'] if entry.is_a?(Hash)
      harness.is_a?(String) ? harness : DEFAULT_NAME
    end

    # The harness module for an entry; KeyError for an unknown name, which
    # config validation rules out before any agent runs.
    module_function def module_for(entry)
      BY_NAME.fetch(name_of(entry))
    end

    # A config entry with its harness's DEFAULT_PROVIDER filled in when it
    # gives no 'provider' (or a null or blank one), so everything after
    # config loading sees one; otherwise the entry itself. An entry that isn't a
    # Hash, or names an unknown harness, is returned as is, for validation
    # to report.
    module_function def with_defaults(entry)
      return entry unless entry.is_a?(Hash)

      provider = entry['provider']
      return entry unless provider.nil? || (provider.is_a?(String) && provider.strip.empty?)

      harness = BY_NAME[name_of(entry)]
      default = harness && harness::DEFAULT_PROVIDER
      default ? entry.merge('provider' => default) : entry
    end
  end
end
