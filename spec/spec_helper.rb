# frozen_string_literal: true

# Enable SimpleCov for this project (coverage output in ./coverage). This must
# run before the library is required so that its files are tracked.
begin
  require 'fileutils'
  require_relative 'simplecov_setup'
  require 'simplecov-cobertura'
  SimpleCov.command_name 'RSpec'
  SimpleCov.formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::CoberturaFormatter,
  ])
  SimpleCovSetup.start
  # SimpleCov merges every result stored in the last merge_timeout seconds
  # and never deletes one. Each end-to-end run stores one of its own, so
  # without this an earlier run's results would count toward this one (and
  # pile up). Deleted after start, which sets the root the path is under.
  FileUtils.rm_f(SimpleCov::ResultMerger.resultset_path)
  # The merged result's name joins every stored result's name, so each
  # formatter's "Coverage report generated for" line would list every
  # end-to-end <pid>. Count them instead. SimpleCov.result is memoized, so
  # the default exit task formats this same, renamed result.
  format_result = SimpleCov.at_exit
  SimpleCov.at_exit do
    result = SimpleCov.result
    if result && (runs = result.command_name.scan(/\bend-to-end \d+/).size).positive?
      result.command_name = "RSpec and #{runs} end-to-end runs"
    end
    format_result.call
  end
rescue LoadError
  warn 'SimpleCov not available; skipping coverage'
end

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

# Matches a block that exits (raises SystemExit) with status.
def exit_with(status) = raise_error(SystemExit) { |e| expect(e.status).to eq(status) }

# A harness's recorded event stream, spec/fixtures/<dir>/<name>.jsonl.
def harness_fixture(dir, name)
  File.read(File.expand_path("fixtures/#{dir}/#{name}.jsonl", __dir__), encoding: 'UTF-8')
end

# events as a JSONL stream, as a harness writes one: a line per event.
def jsonl_stream(*events) = events.map { |event| "#{JSON.generate(event)}\n" }.join

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
