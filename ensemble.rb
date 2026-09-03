#!/usr/bin/env ruby
# frozen_string_literal: true

# ensemble.rb — executable entry point. All code lives in lib/:
#   lib/ensemble.rb    harness-agnostic orchestration (Ensemble)
#   lib/pi_harness.rb  pi-specific behavior (PiHarness)
#
# Usage:
#   ./ensemble.rb PROMPT_FILE [CONFIG_FILE]     (or: ruby ensemble.rb ...)
#
# CONFIG_FILE defaults to ensemble.yml next to this script. Run FROM the
# repository you want analyzed: the harness analyzes its own cwd.

require_relative 'lib/ensemble'

Ensemble.main(ARGV) if __FILE__ == $PROGRAM_NAME
