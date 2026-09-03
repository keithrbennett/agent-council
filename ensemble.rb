#!/usr/bin/env ruby
# frozen_string_literal: true

# ensemble.rb — run one analytical prompt through several models via an
# agent harness and save each model's final response to reports/.
# Harness-specific behavior lives in pi_harness.rb (PiHarness).
#
# Usage:
#   ruby ensemble.rb PROMPT_FILE [CONFIG_FILE]
#
# CONFIG_FILE defaults to ensemble.yml next to this script.
# Run this FROM the repository you want analyzed: the harness analyzes its
# own cwd.

require 'yaml'
require 'open3'
require 'fileutils'
require 'tmpdir'

require_relative 'pi_harness'

module Ensemble
  REPORTS_DIR = File.expand_path('reports', __dir__)
  DEFAULT_CONFIG = File.expand_path('ensemble.yml', __dir__)

  # The harness every model runs through; the single swap point. A second
  # harness would be another module shaped like PiHarness, assigned here.
  HARNESS = PiHarness

  module_function

  # Make an identifier safe for a filename component.
  def sanitize(part)
    part.to_s.gsub(/[^A-Za-z0-9._-]+/, '-').gsub(/\A[-.]+|[-.]+\z/, '')
  end

  # Meaningful query slug, derived from the prompt file name. Convention:
  # prompt files end in _prompt.md; the suffix is stripped from the slug.
  # 'prompts/code-base-state_prompt.md' -> 'code-base-state'
  def query_slug(prompt_path)
    name = File.basename(prompt_path, File.extname(prompt_path)).sub(/_prompt\z/i, '')
    slug = sanitize(name).downcase
    slug.empty? ? 'prompt' : slug
  end

  # <run_stamp>_<query-slug>_<harness>_<provider>_<model>.md — the full
  # timestamp and slug live in the filename so reports stay self-describing
  # when copied out of the reports tree.
  def report_filename(file_prefix, provider, model)
    "#{file_prefix}_#{HARNESS::NAME}_#{sanitize(provider)}_#{sanitize(model)}.md"
  end
end

# Returns [label, ok, detail]; never raises.
def run_agent(agent, prompt, run_dir, file_prefix)
  provider = agent['provider'] if agent.is_a?(Hash)
  model = agent['model'] if agent.is_a?(Hash)
  label = "#{provider} / #{model}"
  return [label, false, "config entry needs 'provider' and 'model'"] if provider.nil? || model.nil?

  Dir.mktmpdir('ensemble-') do |scratch_dir|
    harness = Ensemble::HARNESS
    argv = harness.argv(provider, model, scratch_dir)
    stdout, stderr, status = Open3.capture3({ 'TMPDIR' => scratch_dir }, *argv, stdin_data: prompt)

    unless status.success?
      detail = stderr.lines.map(&:strip).reject(&:empty?).first || 'no error output'
      return [label, false, "#{harness::NAME} exited #{status.exitstatus}: #{detail}"]
    end

    text = harness.final_response(stdout)
    if text.nil? || text.strip.empty?
      error = harness.error_message(stdout)
      detail =
        if error
          "provider error: #{error.gsub(/\s+/, ' ').slice(0, 300)}"
        else
          saw_assistant = harness.assistant_messages(stdout).any?
          if saw_assistant
            'final assistant message had no text content (model may have answered in reasoning only)'
          else
            "no assistant message in #{harness::NAME} event stream"
          end
        end
      return [label, false, "#{harness::NAME} exited 0 but #{detail}"]
    end

    filename = Ensemble.report_filename(file_prefix, provider, model)
    File.write(File.join(run_dir, filename), text)
    [label, true, filename]
  end
rescue => e
  [label, false, "#{e.class}: #{e.message}"]
end

def main
  prompt_path = ARGV[0]
  config_path = ARGV[1] || Ensemble::DEFAULT_CONFIG

  if prompt_path.nil? || ARGV.length > 2
    warn 'Usage: ruby ensemble.rb PROMPT_FILE [CONFIG_FILE]'
    exit 1
  end
  abort "Prompt file not found: #{prompt_path}" unless File.file?(prompt_path)
  abort "Config file not found: #{config_path}" unless File.file?(config_path)

  # Read once; these exact bytes are piped to every pi invocation.
  prompt = File.read(prompt_path)
  abort "Prompt file is empty: #{prompt_path}" if prompt.empty?

  agents = YAML.load_file(config_path)['agents']
  abort "No agents defined in #{config_path}" unless agents.is_a?(Array) && !agents.empty?

  # One run dir per invocation, day-bucketed so reports/ stays navigable at
  # volume: reports/<yyyy-mm-dd>/<hh-mm-ss>/. The dir name is pure time;
  # full timestamp and query slug go into the report filenames (file_prefix).
  now = Time.now
  day = now.strftime('%Y-%m-%d')
  run_name = now.strftime('%H-%M-%S')
  file_prefix = "#{day}-#{run_name}_#{Ensemble.query_slug(prompt_path)}"
  run_dir = File.join(Ensemble::REPORTS_DIR, day, run_name)
  FileUtils.mkdir_p(run_dir)

  # Self-contained run: preserve the exact inputs — prompt and config.
  # (The orchestrator is not copied: it is versioned in git and may grow
  # into multiple files.)
  FileUtils.cp(prompt_path, run_dir)
  FileUtils.cp(config_path, run_dir)

  # Convenience pointer to the newest run: reports/latest
  update_latest_symlink(File.join(day, run_name))

  puts "Running #{agents.size} model(s) with prompt: #{prompt_path}"
  results = agents.map do |agent|
    Thread.new do
      result = run_agent(agent, prompt, run_dir, file_prefix)
      label, ok, detail = result
      puts(ok ? "  ✓ #{label} finished" : "  ✗ #{label} failed: #{detail}")
      result
    end
  end.map(&:value)

  puts "\nSummary:"
  results.each do |label, ok, detail|
    puts(ok ? "  ✓ #{label}  ->  #{detail}" : "  ✗ #{label}  (#{detail})")
  end

  failed = results.count { |_, ok, _| !ok }
  puts "\n#{results.size - failed}/#{results.size} succeeded. Reports in: #{run_dir}"
  exit(failed.zero? ? 0 : 1)
end

# Points reports/latest at the newest run dir (relative link, so the
# reports tree stays movable).
def update_latest_symlink(relative_run_dir)
  link = File.join(Ensemble::REPORTS_DIR, 'latest')
  File.delete(link) if File.symlink?(link)
  File.symlink(relative_run_dir, link)
rescue SystemCallError => e
  warn "note: could not update reports/latest symlink: #{e.message}"
end

main if __FILE__ == $PROGRAM_NAME
