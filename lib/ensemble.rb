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
  CONSOLIDATE_PROMPT_PATH = File.join(PROJECT_ROOT, 'prompts', 'consolidate_prompt.md')

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
  # filename: overrides the output name; meta: becomes YAML front matter.
  def run_agent(agent, prompt, run_dir, file_prefix, filename: nil, meta: {})
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

      filename ||= report_filename(file_prefix, provider, model)
      content = with_front_matter(meta.merge('harness' => HARNESS::NAME,
                                             'provider' => provider,
                                             'model' => model), text)
      File.write(File.join(run_dir, filename), content)
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

  # A run's analyst reports as [source_label, body] pairs, sorted by
  # filename. The dir is the run's answers/ subdir; provider/model labels
  # come from the YAML front matter run_agent writes — not from filename
  # parsing. Files without parseable front matter are not ours and are
  # skipped.
  def collect_reports(answers_dir)
    Dir.glob(File.join(answers_dir, '*.md')).sort.filter_map do |path|
      fields, body = parse_front_matter(File.read(path))
      next unless fields && fields['provider'] && fields['model']

      ["#{fields['provider']} / #{fields['model']}", body]
    end
  end

  # --- report front matter ---

  def with_front_matter(fields, body)
    header = fields.flat_map do |key, value|
      if value.is_a?(Array)
        ["#{key}:", *value.map { |item| "  - #{item}" }]
      else
        ["#{key}: #{yaml_scalar(value)}"]
      end
    end.join("\n")
    <<~TEXT
      ---
      #{header}
      ---

      #{body}
    TEXT
  end

  def yaml_scalar(value)
    value.to_s
  end

  # [fields, body] from a report file, or [nil, nil] if it has no YAML
  # front matter block (or the block cannot be safe-loaded).
  def parse_front_matter(text)
    match = text.match(/\A---\n(.+?)\n---\n\n?/m)
    return [nil, nil] unless match

    fields =
      begin
        YAML.safe_load(match[1], permitted_classes: [Time])
      rescue Psych::Exception, Psych::SyntaxError
        nil
      end
    return [nil, nil] unless fields.is_a?(Hash)

    [fields, match.post_match]
  end

  # The consolidator's substantive prompt: the instructions template, the
  # original prompt every analyst answered, and all reports with their
  # source labels.
  def consolidation_prompt(original_prompt, reports)
    template = File.read(CONSOLIDATE_PROMPT_PATH)
    body = reports.map { |label, text| "## Report from #{label}\n\n#{text}" }.join("\n\n---\n\n")
    <<~MARKDOWN
      #{template}

      ---

      # Original prompt (given identically to every analyst)

      #{original_prompt}

      ---

      # Analyst reports

      #{body}
    MARKDOWN
  end

  # The consolidator's output filename; lives in the run's consolidated/
  # subdir, and stays self-describing when copied out of the tree.
  def consolidated_filename(file_prefix, provider, model)
    "#{file_prefix}_consolidated_#{HARNESS::NAME}_#{sanitize(provider)}_#{sanitize(model)}.md"
  end

  # Runs the configured consolidator model over a run's reports and writes
  # its report into the same run dir. Returns [label, ok, detail].
  def run_consolidation(consolidator, original_prompt, run_dir, file_prefix, meta: {})
    provider = consolidator['provider'] if consolidator.is_a?(Hash)
    model = consolidator['model'] if consolidator.is_a?(Hash)
    return ['consolidator', false, "config entry needs 'provider' and 'model'"] if provider.nil? || model.nil?

    reports = collect_reports(File.join(run_dir, 'answers'))
    if reports.empty?
      return ["#{provider} / #{model} (consolidator)", false,
              "no reports found in #{relative_path(File.join(run_dir, 'answers'))}"]
    end

    consolidated_dir = File.join(run_dir, 'consolidated')
    FileUtils.mkdir_p(consolidated_dir)
    prompt = consolidation_prompt(original_prompt, reports)
    label, ok, detail = run_agent(consolidator, prompt, consolidated_dir, file_prefix,
                                  filename: consolidated_filename(file_prefix, provider, model),
                                  meta: meta.merge('role' => 'consolidator',
                                                   'sources' => reports.map(&:first)))
    ["#{label} (consolidator)", ok, detail]
  end

  def relative_path(path)
    path = File.expand_path(path)
    cwd = File.expand_path(Dir.pwd)
    return path unless path == cwd || path.start_with?(cwd + File::SEPARATOR)

    path.delete_prefix(cwd + File::SEPARATOR)
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

    config = YAML.load_file(config_path)
    agents = config['agents']
    abort "No agents defined in #{config_path}" unless agents.is_a?(Array) && !agents.empty?
    consolidator = config['consolidator']
    if consolidator && !File.file?(CONSOLIDATE_PROMPT_PATH)
      abort "Consolidator configured but template missing: #{CONSOLIDATE_PROMPT_PATH}"
    end

    # One run dir per invocation, day-bucketed so reports/ stays navigable at
    # volume: reports/<yyyy-mm-dd>/<hh-mm-ss>/. The dir name is pure time;
    # full timestamp and query slug go into the report filenames (file_prefix).
    now = Time.now
    day = now.strftime('%Y-%m-%d')
    run_name = now.strftime('%H-%M-%S')
    run_stamp = "#{day}-#{run_name}"
    iso_stamp = now.strftime('%Y-%m-%dT%H:%M:%S')
    slug = query_slug(prompt_path)
    file_prefix = "#{run_stamp}_#{slug}"
    report_meta = { 'role' => 'analyst', 'timestamp' => iso_stamp, 'query' => slug }
    run_dir = File.join(reports_dir, day, run_name)
    answers_dir = File.join(run_dir, 'answers')
    FileUtils.mkdir_p(answers_dir)

    # Self-contained run: preserve the exact inputs — prompt and config.
    # (The orchestrator is not copied: it is versioned in git.)
    FileUtils.cp(prompt_path, run_dir)
    FileUtils.cp(config_path, run_dir)

    # Convenience pointer to the newest run: reports/latest
    update_latest_symlink(File.join(day, run_name))

    puts "Running #{agents.size} model(s) with prompt: #{prompt_path}"
    results = agents.map do |agent|
      Thread.new do
        result = run_agent(agent, prompt, answers_dir, file_prefix, meta: report_meta)
        label, ok, detail = result
        puts(ok ? "  ✓ #{label} finished" : "  ✗ #{label} failed: #{detail}")
        result
      end
    end.map(&:value)

    if consolidator
      puts 'Consolidating reports...'
      label, ok, detail = run_consolidation(consolidator, prompt, run_dir, file_prefix, meta: report_meta)
      puts(ok ? "  ✓ #{label}  ->  #{detail}" : "  ✗ #{label}  (#{detail})")
    end

    puts "\nSummary:"
    results.each do |label, ok, detail|
      puts(ok ? "  ✓ #{label}  ->  #{detail}" : "  ✗ #{label}  (#{detail})")
    end

    failed = results.count { |_, ok, _| !ok }
    puts "\n#{results.size - failed}/#{results.size} succeeded. Reports in: #{relative_path(answers_dir)}"
    exit(failed.zero? ? 0 : 1)
  end
end
