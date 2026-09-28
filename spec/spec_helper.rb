# frozen_string_literal: true

# Make lib/ loadable as `require 'agent_council'`, mirroring how the gem
# itself resolves files relative to lib/ (rather than the project root).
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'agent_council'
