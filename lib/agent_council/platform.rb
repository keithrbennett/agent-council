# frozen_string_literal: true

# Kept free of other project requires so both executables can load it:
# pi-models doesn't load lib/agent_council.rb.

require 'rbconfig'

module AgentCouncil
  # host_os rather than RUBY_PLATFORM, which is "java" on JRuby whatever the
  # OS, and rather than Gem.win_platform?, so as not to depend on RubyGems.
  module_function def windows?
    /mswin|mingw/.match?(RbConfig::CONFIG['host_os'])
  end

  # Native Windows is unsupported; WSL works as Linux does. Ruby runs npm's
  # pi.cmd through cmd.exe, which truncates arguments at newlines (breaking
  # the multi-line system prompt), and WorkerPool relies on process groups
  # and SIGTERM.
  module_function def abort_if_native_windows
    return unless windows?

    abort <<~MESSAGE
      agent-council does not support native Windows; please run it inside WSL.
      See "Prerequisites" in #{File.expand_path('../../README.md', __dir__)}
    MESSAGE
  end
end
