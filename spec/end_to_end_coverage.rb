# frozen_string_literal: true

# Loaded (ruby -r) into each agent-council process the end-to-end spec runs,
# so that what those runs execute counts toward the suite's coverage. Each
# process stores its result under a name of its own, and the RSpec process
# merges them and writes the report. A process that ends by a signal or
# exit! (as an interrupted one does) runs no at_exit hooks, so it stores
# nothing.
require_relative 'simplecov_setup'

SimpleCov.command_name "end-to-end #{Process.pid}"
SimpleCov.finalize_merge false # the RSpec process reports
SimpleCov.print_errors false # the end-to-end spec checks the process's stderr
SimpleCovSetup.start
