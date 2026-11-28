# frozen_string_literal: true

require 'simplecov'

# SimpleCov setup shared by the RSpec process (see spec_helper.rb) and the
# agent-council processes the end-to-end spec runs (see
# end_to_end_coverage.rb), so that all of them measure the same files the
# same way.
module SimpleCovSetup
  # Starts SimpleCov for lib/, including files nothing loads. The root is
  # given because end-to-end runs start in a temporary directory.
  module_function def start
    SimpleCov.root(File.expand_path('..', __dir__))
    SimpleCov.enable_coverage :branch
    # Long enough that the first stored result of a slow run is still
    # merged at its end; earlier runs' results are deleted instead (see
    # spec_helper.rb).
    SimpleCov.merge_timeout 3600
    SimpleCov.start { cover 'lib/**/*.rb' }
    @started = true
  end

  module_function def started? = @started || false
end
