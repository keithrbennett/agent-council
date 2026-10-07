# frozen_string_literal: true

# AgentCouncil — harness-agnostic orchestration: naming, run-directory
# layout, per-agent subprocess execution, and the CLI entry point.
# Harness-specific behavior lives under AgentCouncil::Harnesses (e.g.
# AgentCouncil::Harnesses::PiHarness); HARNESS below is the single swap
# point.

require 'yaml'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'optparse'

require_relative 'agent_council/version'
require_relative 'agent_council/harnesses/pi_harness'

module AgentCouncil
  # Runtime data files (prompt templates) ship inside lib/, resolved
  # relative to this file, so the gem is self-contained: what gets loaded at runtime never depends on which
  # files happen to survive the gemspec's file list. PROJECT_ROOT remains
  # only for documentation references (e.g. the local README path in help
  # text), not for runtime data.
  PROJECT_ROOT = File.expand_path('..', __dir__)
  TEMPLATES_DIR = File.join(__dir__, 'agent_council', 'templates')
  CONSOLIDATE_PROMPT_PATH = File.join(TEMPLATES_DIR, 'consolidate_prompt.md')
  ANALYST_FORMAT_PATH = File.join(TEMPLATES_DIR, 'analyst_format.md')

  # The harness every model runs through; the single swap point. A second
  # harness would be another module under AgentCouncil::Harnesses,
  # assigned here.
  HARNESS = AgentCouncil::Harnesses::PiHarness

  # Reports go under the current working directory — i.e. alongside the
  # repository being analyzed — so the tool can be run from any project.
  # If the working directory has an untracked/ directory (a conventional
  # home for git-ignored scratch files), reports go in untracked/reports
  # instead of reports, so they don't clutter the project root.
  module_function def reports_dir
    base = File.directory?(File.join(Dir.pwd, 'untracked')) ? File.join(Dir.pwd, 'untracked') : Dir.pwd
    File.join(base, 'reports')
  end

  # Config file names picked up when no CONFIG_FILE argument is given: a
  # visible per-project file in the current working directory, and a hidden
  # (dotfile) per-user file in the home directory.
  CWD_CONFIG_NAME = 'agent-council.yml'
  HOME_CONFIG_NAME = '.agent-council.yml'

  # The explicit CONFIG_FILE argument if given, else ./agent-council.yml if
  # it exists, else ~/.agent-council.yml if it exists; nil when none apply.
  # Only the cwd is checked (no upward walk), consistent with reports_dir.
  module_function def resolve_config_path(explicit)
    return explicit if explicit

    candidates = [File.join(Dir.pwd, CWD_CONFIG_NAME)]
    begin
      home = Dir.home
      candidates << File.join(home, HOME_CONFIG_NAME) unless home.empty?
    rescue ArgumentError
      # No resolvable home directory; only the cwd candidate applies.
    end
    candidates.find { |path| File.file?(path) }
  end

  # Make an identifier safe for a filename component.
  module_function def sanitize(part)
    part.to_s.gsub(/[^A-Za-z0-9._-]+/, '-').gsub(/\A[-.]+|[-.]+\z/, '')
  end

  # Meaningful query slug, derived from the prompt file name. A trailing
  # -prompt or _prompt suffix is stripped from the slug.
  module_function def query_slug(prompt_path)
    name = File.basename(prompt_path, File.extname(prompt_path)).sub(/[-_]prompt\z/i, '')
    slug = sanitize(name).downcase
    slug.empty? ? 'prompt' : slug
  end

  # <run_stamp>_<query-slug>[_<index>]_<harness>_<provider>_<model>.md — the
  # full timestamp and slug live in the filename so reports stay
  # self-describing when copied out of the reports tree. index (an agent's
  # 1-based position in the config's agent list) disambiguates repeated
  # provider/model entries — e.g. the same model configured twice to spread
  # load across a rate-limited subscription — without depending on it being
  # unique. It sits before the harness so that once more than one harness
  # exists, filenames still sort in config/agent order first, rather than
  # grouping by harness.
  module_function def report_filename(file_prefix, provider, model, index: nil)
    parts = [file_prefix]
    parts << format('%02d', index) if index
    parts << HARNESS::NAME
    parts += [sanitize(provider), sanitize(model)]
    "#{parts.join('_')}.md"
  end

  # Returns [label, ok, detail]; never raises.
  # index: the agent's 1-based position in the config's agent list, used to
  # disambiguate repeated provider/model entries in the filename and label;
  # filename: overrides the output name; meta: becomes YAML front matter;
  # header: markdown prepended to the report body. If the response begins
  # with an H1 of its own, it is dropped to avoid a duplicated title.
  module_function def run_agent(agent, prompt, run_dir, file_prefix, index: nil, filename: nil, meta: {},
    header: nil)
    provider = agent['provider'] if agent.is_a?(Hash)
    model = agent['model'] if agent.is_a?(Hash)
    label = index ? "##{index} #{provider} / #{model}" : "#{provider} / #{model}"
    return [label, false, "config entry needs 'provider' and 'model'"] if provider.nil? || model.nil?

    Dir.mktmpdir('agent-council-') do |scratch_dir|
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

      filename ||= report_filename(file_prefix, provider, model, index: index)
      if header
        text = text.sub(/\A\s*#(?!#).+\n+/, '')
        text = "#{header}\n#{text}"
      end
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
  module_function def update_latest_symlink(relative_run_dir)
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
  module_function def collect_reports(answers_dir)
    Dir.glob(File.join(answers_dir, '*.md')).filter_map do |path|
      fields, body = parse_front_matter(File.read(path))
      next unless fields && fields['provider'] && fields['model']

      index = fields['agent_index']
      plain = "#{fields['provider']} / #{fields['model']}"
      [index ? "##{index} #{plain}" : plain, body]
    end
  end

  # --- report front matter ---

  module_function def with_front_matter(fields, body)
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

  module_function def yaml_scalar(value)
    value.to_s
  end

  # [fields, body] from a report file, or [nil, nil] if it has no YAML
  # front matter block (or the block cannot be safe-loaded).
  module_function def parse_front_matter(text)
    match = text.match(/\A---\n(.+?)\n---\n\n?/m)
    return [nil, nil] unless match

    fields =
      begin
        YAML.safe_load(match[1], permitted_classes: [Time])
      rescue Psych::Exception
        nil
      end
    return [nil, nil] unless fields.is_a?(Hash)

    [fields, match.post_match]
  end

  # The exact bytes piped to each analyst harness: the user's prompt
  # verbatim, then the report-format addendum.
  module_function def compose_analyst_prompt(prompt, addendum)
    "#{prompt.chomp}\n\n#{addendum}"
  end

  # The consolidator's substantive prompt: the instructions template, the
  # original prompt every analyst answered, and all reports with their
  # source labels.
  module_function def consolidation_prompt(original_prompt, reports)
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

  # The consolidator's output filename; lives at the top level of the run
  # dir, and stays self-describing when copied out of the tree.
  module_function def consolidated_filename(file_prefix, provider, model)
    "#{file_prefix}_consolidated_#{HARNESS::NAME}_#{sanitize(provider)}_#{sanitize(model)}.md"
  end

  # Centered markdown table mirroring the report's front matter, placed
  # under the report title; one row per consulted agent, when present.
  module_function def byline_table(meta, provider, model)
    fields = {
      'role'      => meta['role'],
      'agent'     => (meta['agent_index'] ? "##{meta['agent_index']}" : nil),
      'query'     => meta['query'],
      'harness'   => HARNESS::NAME,
      'provider'  => provider,
      'model'     => model,
      'timestamp' => meta['timestamp'],
    }.compact
    rows = fields.map { |field, value| "| #{field} | #{value} |" }
    rows += Array(meta['sources']).map { |label| "| source | #{label} |" }
    <<~TABLE
      | Field     | Value |
      | :-------- | :---------------------------- |
      #{rows.join("\n")}
    TABLE
  end

  # Runs the configured consolidator model over a run's reports and writes
  # its report into the same run dir. Returns [label, ok, detail].
  module_function def run_consolidation(consolidator, original_prompt, run_dir, file_prefix,
    meta: {}, prompt_path: nil)
    provider = consolidator['provider'] if consolidator.is_a?(Hash)
    model = consolidator['model'] if consolidator.is_a?(Hash)
    return ['consolidator', false, "config entry needs 'provider' and 'model'"] if provider.nil? || model.nil?

    reports = collect_reports(File.join(run_dir, 'answers'))
    if reports.empty?
      return ["#{provider} / #{model} (consolidator)", false,
        "no reports found in #{relative_path(File.join(run_dir, 'answers'))}"]
    end

    prompt = consolidation_prompt(original_prompt, reports)
    meta = meta.merge('role' => 'consolidator', 'sources' => reports.map(&:first))
    prompt_line = prompt_path ? "### Prompt: #{prompt_path}\n\n" : ''
    header = "# Consolidated Report\n\n#{prompt_line}#{byline_table(meta, provider, model)}"
    label, ok, detail = run_agent(consolidator, prompt, run_dir, file_prefix,
      filename: consolidated_filename(file_prefix, provider, model),
      header:   header,
      meta:     meta)
    ["#{label} (consolidator)", ok, detail]
  end

  module_function def relative_path(path)
    path = File.expand_path(path)
    cwd = File.expand_path(Dir.pwd)
    return path unless path == cwd || path.start_with?(cwd + File::SEPARATOR)

    path.delete_prefix(cwd + File::SEPARATOR)
  end

  # Whole seconds as HH:MM:SS (hours may exceed 99); rounds to the nearest second.
  module_function def format_duration(seconds)
    total = seconds.round
    format('%02d:%02d:%02d', total / 3600, total % 3600 / 60, total % 60)
  end

  # Runs the block; returns [block_result, elapsed_seconds] (monotonic clock).
  module_function def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  # One result line: "✓ duration  label  ->  report_path" on success,
  # "✗ duration  label  (error)" on failure.
  module_function def format_result_line(label, ok, detail, elapsed)
    duration = format_duration(elapsed)
    ok ? "  ✓ #{duration}  #{label}  ->  #{detail}" : "  ✗ #{duration}  #{label}  (#{detail})"
  end

  # True if a config entry (agent or consolidator) has the required string
  # 'provider' and 'model' fields.
  module_function def valid_agent_entry?(entry)
    entry.is_a?(Hash) && entry['provider'].is_a?(String) && entry['model'].is_a?(String)
  end

  # "harness / provider / model" for a validated config entry, printed at
  # startup so it is clear which agents are still running later.
  module_function def agent_descriptor(entry)
    "#{HARNESS::NAME} / #{entry['provider']} / #{entry['model']}"
  end

  module_function def option_parser
    OptionParser.new do |opts|
      opts.banner = <<~BANNER
        -------------------------------------------------------------------------------
        Usage:                 agent-council [options] PROMPT_FILE [CONFIG_FILE]
        Repository:            https://github.com/keithrbennett/agent-council
        Documentation (Local): #{File.join(PROJECT_ROOT, 'README.md')}
        Version:               #{VERSION}
        -------------------------------------------------------------------------------

        Arguments:
          PROMPT_FILE   Path to the prompt file to send to every configured model (required)
          CONFIG_FILE   Path to a YAML agent config (default: ./#{CWD_CONFIG_NAME}, else ~/#{HOME_CONFIG_NAME}, if present)

        Options:
      BANNER

      opts.on('-h', '--help', 'Show this help and exit') do
        puts opts
        exit 0
      end

      opts.separator ''
      opts.separator 'Examples:'
      opts.separator '  agent-council my-analysis-prompt.md'
      opts.separator '  agent-council my-analysis-prompt.md other-config.yml'
    end
  end

  module_function def main(argv)
    parser = option_parser
    begin
      argv = parser.parse(argv)
    rescue OptionParser::ParseError => e
      warn e.message
      warn parser
      exit 1
    end

    prompt_path = argv[0]

    if prompt_path.nil? || argv.length > 2
      warn parser
      exit 1
    end
    abort "Prompt file not found: #{prompt_path}" unless File.file?(prompt_path)

    config_path = resolve_config_path(argv[1])
    unless config_path
      abort <<~MESSAGE
        No config file given, and neither ./#{CWD_CONFIG_NAME} nor ~/#{HOME_CONFIG_NAME} exists.
        Pass a config path: agent-council PROMPT_FILE CONFIG_FILE
        See examples/configs/ in the repository for sample configs.
      MESSAGE
    end
    abort "Config file not found: #{config_path}" unless File.file?(config_path)
    warn "No config file given; using default config file: #{File.expand_path(config_path)}" unless argv[1]

    # Read once. Analysts receive the user's prompt verbatim, followed by
    # the report-format addendum; the consolidator cites the prompt alone.
    # Both input files are copied into the run dir, so the exact bytes sent
    # to each harness are recoverable.
    prompt = File.read(prompt_path)
    abort "Prompt file is empty: #{prompt_path}" if prompt.empty?
    abort "Analyst format addendum missing: #{ANALYST_FORMAT_PATH}" unless File.file?(ANALYST_FORMAT_PATH)
    analyst_prompt = compose_analyst_prompt(prompt, File.read(ANALYST_FORMAT_PATH))

    config =
      begin
        YAML.safe_load_file(config_path)
      rescue Psych::Exception => e
        abort "Invalid YAML in #{config_path}: #{e.message}"
      end
    abort "Config file must be a YAML mapping: #{config_path}" unless config.is_a?(Hash)

    agents = config['agents']
    abort "No agents defined in #{config_path}" unless agents.is_a?(Array) && !agents.empty?
    unless agents.all? { |a| valid_agent_entry?(a) }
      abort "Each agent in #{config_path} needs string 'provider' and 'model' fields"
    end

    consolidator = config['consolidator']
    if consolidator
      unless valid_agent_entry?(consolidator)
        abort "Consolidator in #{config_path} needs string 'provider' and 'model' fields"
      end
      unless File.file?(CONSOLIDATE_PROMPT_PATH)
        abort "Consolidator configured but template missing: #{CONSOLIDATE_PROMPT_PATH}"
      end
    end

    # One run dir per invocation, day-bucketed so reports/ stays navigable at
    # volume: reports/<yyyy-mm-dd>/<hh-mm-ss>/. The dir name is pure time;
    # full timestamp and query slug go into the report filenames (file_prefix).
    now = Time.now
    day = now.strftime('%Y-%m-%d')
    run_name = now.strftime('%H-%M-%S')
    run_stamp = "#{day}-#{run_name}"
    iso_stamp = now.strftime('%Y-%m-%dT%H:%M:%S%:z')
    slug = query_slug(prompt_path)
    file_prefix = "#{run_stamp}_#{slug}"
    report_meta = { 'role' => 'analyst', 'timestamp' => iso_stamp, 'query' => slug }
    run_dir = File.join(reports_dir, day, run_name)
    answers_dir = File.join(run_dir, 'answers')
    FileUtils.mkdir_p(answers_dir)

    # Self-contained run: preserve the exact inputs — prompt, format
    # addendum, and config. (The orchestrator is not copied: it is
    # versioned in git.)
    FileUtils.cp(prompt_path, run_dir)
    FileUtils.cp(ANALYST_FORMAT_PATH, run_dir)
    FileUtils.cp(config_path, run_dir)

    # Convenience pointer to the newest run: reports/latest
    update_latest_symlink(File.join(day, run_name))

    puts "\nPrompt: #{prompt_path}"
    puts "\nAgents (#{agents.size}):"
    agents.each_with_index do |agent, i|
      puts "  ##{i + 1} #{agent_descriptor(agent)}"
    end
    puts "\nConsolidator:\n  #{agent_descriptor(consolidator)}" if consolidator
    puts "\nProgress:"
    results = agents.each_with_index.map do |agent, i|
      index = i + 1
      Thread.new do
        provider = agent.is_a?(Hash) ? agent['provider'] : nil
        model = agent.is_a?(Hash) ? agent['model'] : nil
        meta = report_meta.merge('agent_index' => index)
        (label, ok, detail), elapsed = timed do
          run_agent(agent, analyst_prompt, answers_dir, file_prefix,
            index:  index,
            meta:   meta,
            header: byline_table(meta, provider, model))
        end
        duration = format_duration(elapsed)
        puts(ok ? "  ✓ #{duration}  #{label}" : "  ✗ #{duration}  #{label}  (#{detail})")
        [label, ok, detail, elapsed]
      end
    end.map(&:value)

    if consolidator
      puts "\nConsolidating reports:"
      (label, ok, detail), elapsed = timed do
        run_consolidation(consolidator, prompt, run_dir, file_prefix,
          meta: report_meta, prompt_path: prompt_path)
      end
      puts format_result_line(label, ok, detail, elapsed)
    end

    puts "\nSummary (duration, agent, report):"
    results.each do |label, ok, detail, elapsed|
      puts format_result_line(label, ok, detail, elapsed)
    end

    failed = results.count { |_, ok, _| !ok }
    puts "\n#{results.size - failed}/#{results.size} succeeded. Reports in: #{relative_path(answers_dir)}"
    exit(failed.zero? ? 0 : 1)
  end
end
