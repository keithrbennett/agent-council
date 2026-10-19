# frozen_string_literal: true

# Make lib/ loadable as `require 'agent_council'`, mirroring how the gem
# itself resolves files relative to lib/ (rather than the project root).
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'agent_council'

RSpec.configure do |config|
  config.around do |example|
    original = ENV[AgentCouncil::ENV_OPTS_VAR]
    ENV.delete(AgentCouncil::ENV_OPTS_VAR)
    example.run
  ensure
    ENV[AgentCouncil::ENV_OPTS_VAR] = original
  end
end

# Runs the block with the default external encoding Ruby picks under LANG=C
# (or LANG unset), to check that code reads text as UTF-8 regardless. The
# library must not depend on the locale, so specs never force it globally.
def with_us_ascii_locale
  original = Encoding.default_external
  verbose, $VERBOSE = $VERBOSE, nil # setting it warns under -w
  Encoding.default_external = Encoding::US_ASCII
  yield
ensure
  Encoding.default_external = original
  $VERBOSE = verbose
end
