# frozen_string_literal: true

# Ensemble — harness-agnostic orchestration: naming, run-directory layout,
# per-agent subprocess execution, and the CLI entry point. Harness-specific
# behavior lives in pi_harness.rb (PiHarness); HARNESS below is the single
# swap point.

require 'yaml'
require 'open3'
require 'fileutils'
require 'tmpdir'

require_relative 'pi_harness'

module Ensemble
  PROJECT_ROOT = File.expand_path('..', __dir__)
  DEFAULT_CONFIG = File.join(PROJECT_ROOT, 'ensemble.yml')

  # The harness every model runs through; the single swap point. A second
  # harness would be another module shaped like PiHarness, assigned here.
  HARNESS = PiHarness

  module_function

  # Reports go under the current working directory — i.e. alongside the
  # repository being analyzed — so the tool can be run from any project.
  def reports_dir
    File.join(Dir.pwd, 'reports')
  end

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

  # Returns [label, ok, detail]; never raises.
  def run_agent(agent, prompt, run_dir, file_prefix)
    provider = agent['provider'] if agent.is_a?(Hash)
    model = agent['model'] if agent.is_a?(Hash)
    label = "#{provider} / #{model}"
    return [label, false, "config entry needs 'provider' and 'model'"] if provider.nil? || model.nil?

    Dir.mktmpdir('ensemble-') do |scratch_dir|
      argv = HARNESS.argv(provider, model, scratch_dir)
      stdout, stderr, status = Open3.capture3({ 'TMPDIR' => scratch_dir }, *argv, stdin_data: prompt)

      unless status.success?
        detail = stderr.lines.map(&:strip).reject(&:empty?).first || 'no error output'
        return [label, false, "#{HARNESS::NAME} exited #{status.exitstatus}: #{detail}"]
      end

      text = HARNESS.final_response(stdout)
      if text.nil? || text.strip.empty?
        error = HARNESS.error_message(stdout)
        detail =
          if error
            "provider error: #{error.gsub(/\s+/, ' ').slice(0, 300)}"
          else
            saw_assistant = HARNESS.assistant_messages(stdout).any?
            if saw_assistant
              'final assistant message had no text content (model may have answered in reasoning only)'
            else
              "no assistant message in #{HARNESS::NAME} event stream"
            end
          end
        return [label, false, "#{HARNESS::NAME} exited 0 but #{detail}"]
      end

      filename = report_filename(file_prefix, provider, model)
      File.write(File.join(run_dir, filename), text)
      [label, true, filename]
    end
  rescue => e
    [label, false, "#{e.class}: #{e.message}"]
  end

  # Points reports/latest at the newest run dir (relative link, so the
  # reports tree stays movable).
  def update_latest_symlink(relative_run_dir)
    link = File.join(reports_dir, 'latest')
    File.delete(link) if File.symlink?(link)
    File.symlink(relative_run_dir, link)
  rescue SystemCallError => e
    warn "note: could not update reports/latest symlink: #{e.message}"
  end

  def main(argv)
    prompt_path = argv[0]
    config_path = argv[1] || DEFAULT_CONFIG

    if prompt_path.nil? || argv.length > 2
      warn 'Usage: ruby ensemble.rb PROMPT_FILE [CONFIG_FILE]'
      exit 1
    end
    abort "Prompt file not found: #{prompt_path}" unless File.file?(prompt_path)
    abort "Config file not found: #{config_path}" unless File.file?(config_path)

    # Read once; these exact bytes are piped to every harness invocation.
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
    file_prefix = "#{day}-#{run_name}_#{query_slug(prompt_path)}"
    run_dir = File.join(reports_dir, day, run_name)
    FileUtils.mkdir_p(run_dir)

    # Self-contained run: preserve the exact inputs — prompt and config.
    # (The orchestrator is not copied: it is versioned in git.)
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
end
