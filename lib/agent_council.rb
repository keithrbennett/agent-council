# frozen_string_literal: true

# AgentCouncil — harness-agnostic orchestration: naming, run-directory
# layout, per-agent subprocess execution, and the CLI entry point.
# Harness-specific behavior lives under AgentCouncil::Harnesses (e.g.
# AgentCouncil::Harnesses::PiHarness); HARNESS below is the single swap
# point.

require 'yaml'
# Psych requires stringio lazily, on first emit. On JRuby, worker threads
# emitting front matter at once can then see a half-loaded StringIO
# (ArgumentError from StringIO.new), so load it before any threads start.
require 'stringio'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'optparse'
require 'shellwords'

require_relative 'agent_council/version'
require_relative 'agent_council/platform'
require_relative 'agent_council/harnesses/pi_harness'
require_relative 'agent_council/worker_pool'

module AgentCouncil
  # Runtime data files (prompt templates) ship inside lib/, resolved
  # relative to this file, so the gem is self-contained: what gets loaded at runtime never depends on which
  # files happen to survive the gemspec's file list. PROJECT_ROOT remains
  # only for documentation references (e.g. the local README path in help
  # text), not for runtime data.
  PROJECT_ROOT = File.expand_path('..', __dir__)
  EXAMPLES_DIR = File.join(PROJECT_ROOT, 'examples')
  TEMPLATES_DIR = File.join(__dir__, 'agent_council', 'templates')
  CONSOLIDATE_PROMPT_PATH = File.join(TEMPLATES_DIR, 'consolidate_prompt.md')
  ANALYST_FORMAT_PATH = File.join(TEMPLATES_DIR, 'analyst_format.md')

  # The harness every model runs through; the single swap point. A second
  # harness would be another module under AgentCouncil::Harnesses,
  # assigned here.
  HARNESS = AgentCouncil::Harnesses::PiHarness

  # After Ctrl-C, how long agents get to exit after SIGTERM before they're
  # killed (see WorkerPool).
  INTERRUPT_GRACE_SECONDS = 5

  # All text read or captured (prompts, templates, reports, harness output)
  # is UTF-8, whatever the locale's default external encoding (US-ASCII
  # under LANG=C or with LANG unset).
  ENCODING = Encoding::UTF_8

  # By default, reports go under the current working directory — i.e.
  # alongside the repository being analyzed — so the tool can be run from
  # any project. The name says which tool wrote them, since they land in
  # someone else's tree.
  DEFAULT_REPORTS_DIR_NAME = 'agent-council-reports'

  # The reports root: the --output-dir value if given (relative paths
  # resolve against the cwd), else ./agent-council-reports.
  module_function def reports_dir(explicit = nil)
    File.expand_path(explicit || DEFAULT_REPORTS_DIR_NAME)
  end

  # Config file names picked up when no CONFIG_FILE argument is given: a
  # visible per-project file in the current working directory, and a hidden
  # (dotfile) per-user file in the home directory.
  CWD_CONFIG_NAME = 'agent-council.yml'
  HOME_CONFIG_NAME = '.agent-council.yml'

  # Shell-style arguments from the environment, inserted before ARGV.
  ENV_OPTS_VAR = 'AGENT_COUNCIL_OPTS'

  # The explicit CONFIG_FILE argument if given, else ./agent-council.yml if
  # it exists, else ~/.agent-council.yml if it exists; nil when none apply.
  # Only the cwd is checked (no upward walk).
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

  # An absolute path with the home directory abbreviated to ~, for recording
  # where an input came from without putting the username in shared reports.
  module_function def display_source_path(path)
    path = File.expand_path(path)
    home = begin
      File.expand_path(Dir.home)
    rescue ArgumentError
      nil
    end
    return path if home.nil? || home.empty? || home == File::SEPARATOR
    return '~' if path == home

    path.start_with?(home + File::SEPARATOR) ? "~#{path.delete_prefix(home)}" : path
  end

  # Make an identifier safe for a filename component.
  module_function def sanitize(part)
    part.to_s.gsub(/[^A-Za-z0-9._-]+/, '-').gsub(/\A[-.]+|[-.]+\z/, '')
  end

  # Meaningful query slug, derived from the prompt file name. The extension
  # and then a trailing -prompt or _prompt (in any case) are stripped.
  module_function def query_slug(prompt_path)
    name = File.basename(prompt_path, File.extname(prompt_path)).sub(/[-_]prompt\z/i, '')
    slug = sanitize(name).downcase
    slug.empty? ? 'prompt' : slug
  end

  # <run_stamp>_<query-slug>[_<index>]_<harness>_<provider>_<model>.md — the
  # full timestamp and slug live in the filename so reports stay
  # self-describing when copied out of the reports tree. index (an agent's
  # 1-based position in the config's agent list) disambiguates repeated
  # provider/model entries — e.g. the same model configured twice for two
  # independent analyses — without depending on it being unique. It sits before the harness so that once more than one harness
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
  # header: markdown prepended to the report body (or a callable receiving the
  # task's HH:MM:SS duration and returning it). If the response begins
  # with an H1 of its own, it is dropped: the header leads the body (and
  # carries the title, in consolidated reports).
  # pool: the WorkerPool to spawn the agent through, so Ctrl-C can stop it;
  # without one it's spawned untracked.
  module_function def run_agent(agent, prompt, run_dir, file_prefix, index: nil, filename: nil, meta: {},
    header: nil, pool: nil)
    provider = agent['provider'] if agent.is_a?(Hash)
    model = agent['model'] if agent.is_a?(Hash)
    label = agent_label(provider, model, index)
    return [label, false, "config entry needs 'provider' and 'model'"] if provider.nil? || model.nil?

    # Removed in the ensure below rather than via Dir.mktmpdir's block form,
    # with errors ignored: a child that is still exiting (e.g. one just
    # killed after the Ctrl-C grace period) can still be writing here
    # (node's compile cache, say). That must not surface as an error.
    scratch_dir = Dir.mktmpdir('agent-council-')
    argv = HARNESS.argv(provider, model, scratch_dir)
    (stdout, stderr, status), elapsed = timed do
      (pool || Open3).capture3({ 'TMPDIR' => scratch_dir }, *argv, stdin_data: prompt)
    end
    # Harness output is UTF-8. WorkerPool#capture3 already returns it as such,
    # but Open3.capture3 (used without a pool) returns the locale's encoding.
    stdout, stderr = [stdout, stderr].map { |output| String.new(output, encoding: ENCODING) }
    duration = format_duration(elapsed)

    unless status.success?
      detail = stderr.lines.map(&:strip).reject(&:empty?).first || 'no error output'
      return [label, false, "#{HARNESS::NAME} exited #{status.exitstatus}: #{detail}"]
    end

    error = HARNESS.error_message(stdout)
    if error
      summary = error.gsub(/\s+/, ' ').slice(0, 300)
      return [label, false, "#{HARNESS::NAME} exited 0 but the run failed: #{summary}"]
    end

    text = HARNESS.final_response(stdout)
    if text.nil? || text.strip.empty?
      detail =
        if HARNESS.assistant_messages(stdout).any?
          'final assistant message had no text content (model may have answered in reasoning only)'
        else
          "no assistant message in #{HARNESS::NAME} event stream"
        end
      return [label, false, "#{HARNESS::NAME} exited 0 but #{detail}"]
    end

    filename ||= report_filename(file_prefix, provider, model, index: index)
    if header
      header = header.call(duration) if header.respond_to?(:call)
      text = text.sub(/\A\s*#(?!#).+\n+/, '')
      text = "#{header}\n#{text}"
    end
    content = with_front_matter(meta.merge('harness' => HARNESS::NAME,
      'provider' => provider,
      'model'    => model,
      'duration' => duration), text)
    # Exclusive create ('x'): never replaces a report, e.g. one written by
    # a concurrent --consolidate with the same model; that is a failure.
    File.write(File.join(run_dir, filename), content, mode: 'wx')
    [label, true, filename]
  rescue => e
    [label, false, "#{e.class}: #{e.message}"]
  ensure
    FileUtils.rm_rf(scratch_dir) if scratch_dir
  end

  # Creates a new run dir in day_dir and returns its name: base, or base-2,
  # base-3, ... if that is taken. Dir.mkdir fails if the dir exists, so the
  # claim is atomic: runs started in the same second (or whose local time
  # repeats, e.g. when clocks fall back) never share a dir.
  module_function def claim_run_dir(day_dir, base)
    FileUtils.mkdir_p(day_dir)
    (1..).each do |n|
      name = n == 1 ? base : "#{base}-#{n}"
      Dir.mkdir(File.join(day_dir, name))
      return name
    rescue Errno::EEXIST
      next
    end
  end

  # The run dir's subdir holding the analysts' reports.
  REVIEWS_DIR_NAME = 'reviews'

  # A run's analyst reports as [source_label, body, fields] triples, sorted
  # by filename; fields is the report's front matter. The dir is the run's
  # reviews/ subdir; provider/model labels come from the YAML front matter
  # run_agent writes — not from filename parsing. Files without parseable
  # front matter naming a provider and model are not ours and are skipped.
  module_function def collect_reports(reviews_dir)
    # base: keeps reviews_dir from being read as a pattern, so a path with
    # glob characters (e.g. "[") still finds its reports.
    Dir.glob('*.md', base: reviews_dir).filter_map do |name|
      fields, body = parse_front_matter(File.read(File.join(reviews_dir, name), encoding: ENCODING))
      next unless fields && fields['provider'] && fields['model']

      [agent_label(fields['provider'], fields['model'], fields['agent_index']), body, fields]
    end
  end

  # --- report front matter ---

  module_function def with_front_matter(fields, body)
    header = YAML.dump(fields.transform_keys(&:to_s)).delete_prefix("---\n").chomp
    # Documented format: ISO 8601 timestamps, with or without a UTC offset,
    # are unquoted (parse as Time).
    iso = /\d{4}-\d\d-\d\dT[\d:]+(?:Z|[+-]\d\d:\d\d)?/
    header = header.gsub(/^(timestamp|consolidated_at): ['"](#{iso})['"]$/, '\\1: \\2')
    <<~TEXT
      ---
      #{header}
      ---

      #{body}
    TEXT
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

  # The exact bytes piped to each analyst harness: the user's prompt, less
  # one trailing newline, then a blank line and the report-format addendum.
  module_function def compose_analyst_prompt(prompt, addendum)
    "#{prompt.chomp}\n\n#{addendum}"
  end

  # An agent's label in progress lines, report sources and consolidation
  # prompts: "#<index> <provider> / <model>", or without the index when
  # there is none (the consolidator). missing_agents matches reports by it.
  module_function def agent_label(provider, model, index = nil)
    plain = "#{provider} / #{model}"
    index ? "##{index} #{plain}" : plain
  end

  # The consolidator's substantive prompt: the instructions template, the
  # original prompt every analyst answered, all reports with their source
  # labels, and the agents without a report, as [label, reason] pairs; the
  # consolidator can't otherwise know about those.
  module_function def consolidation_prompt(original_prompt, reports, failures = [])
    template = File.read(CONSOLIDATE_PROMPT_PATH, encoding: ENCODING)
    body = reports.map { |label, text| "## Report from #{label}\n\n#{text}" }.join("\n\n---\n\n")
    failed = failures.empty? ? 'None.' : failures.map { |label, reason| "- #{label}: #{reason}" }.join("\n")
    <<~MARKDOWN
      #{template}

      ---

      # Original prompt (given identically to every analyst)

      #{original_prompt}

      ---

      # Analyst reports

      #{body}

      ---

      # Agents without a report

      #{failed}
    MARKDOWN
  end

  # The consolidator's output filename; lives at the top level of the run
  # dir, and stays self-describing when copied out of the tree.
  module_function def consolidated_filename(file_prefix, provider, model)
    "#{file_prefix}_consolidated_#{HARNESS::NAME}_#{sanitize(provider)}_#{sanitize(model)}.md"
  end

  # Markdown table of the report's main front-matter fields, leading the
  # body (under the title, in consolidated reports); one row per consulted
  # agent, when present.
  module_function def byline_table(meta, provider, model)
    fields = {
      'role'            => meta['role'],
      'agent'           => (meta['agent_index'] ? "##{meta['agent_index']}" : nil),
      'query'           => meta['query'],
      'harness'         => HARNESS::NAME,
      'provider'        => provider,
      'model'           => model,
      'timestamp'       => meta['timestamp'],
      'consolidated_at' => meta['consolidated_at'],
      'duration'        => meta['duration'],
    }.compact
    rows = fields.map { |field, value| "| #{field} | #{value} |" }
    source_durations = meta['source_durations'] || {}
    rows += Array(meta['sources']).map do |label|
      duration = source_durations[label]
      "| source | #{label}#{" (#{duration})" if duration} |"
    end
    <<~TABLE
      | Field     | Value |
      | :-------- | :---------------------------- |
      #{rows.join("\n")}
    TABLE
  end

  # Runs the configured consolidator model over a run's reports and writes
  # its report into the same run dir. Returns [label, ok, detail]; never
  # raises. Each source's duration comes from its report's front matter.
  # failures: as for consolidation_prompt. pool: as for run_agent.
  module_function def run_consolidation(consolidator, original_prompt, run_dir, file_prefix,
    meta: {}, prompt_path: nil, failures: [], pool: nil)
    provider = consolidator['provider'] if consolidator.is_a?(Hash)
    model = consolidator['model'] if consolidator.is_a?(Hash)
    return ['consolidator', false, "config entry needs 'provider' and 'model'"] if provider.nil? || model.nil?

    reports = collect_reports(File.join(run_dir, REVIEWS_DIR_NAME))
    if reports.empty?
      return [agent_label(provider, model), false,
        "no reports found in #{relative_path(File.join(run_dir, REVIEWS_DIR_NAME))}"]
    end

    prompt = consolidation_prompt(original_prompt, reports, failures)
    source_durations = reports.to_h { |label, _, fields| [label, fields['duration']] }.compact
    # timestamp is the run's start; consolidated_at is this consolidation's,
    # which is later when done by --consolidate.
    meta = meta.merge('role' => 'consolidator', 'consolidated_at' => iso_timestamp(Time.now),
      'sources' => reports.map(&:first), 'source_durations' => source_durations)
    prompt_line = prompt_path ? "### Prompt: #{prompt_path}\n\n" : ''
    header = ->(duration) do
      "# Consolidated Report\n\n#{prompt_line}" \
        "#{byline_table(meta.merge('duration' => duration), provider, model)}"
    end
    run_agent(consolidator, prompt, run_dir, file_prefix,
      filename: consolidated_filename(file_prefix, provider, model),
      header:   header,
      meta:     meta,
      pool:     pool)
  rescue => e
    [agent_label(provider, model), false, "#{e.class}: #{e.message}"]
  end

  module_function def relative_path(path)
    path = File.expand_path(path)
    cwd = File.expand_path(Dir.pwd)
    return path unless path == cwd || path.start_with?(cwd + File::SEPARATOR)

    path.delete_prefix(cwd + File::SEPARATOR)
  end

  # The front matter's timestamp format: ISO 8601 with the UTC offset.
  module_function def iso_timestamp(time)
    time.strftime('%Y-%m-%dT%H:%M:%S%:z')
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

  RESULT_HEADINGS = %w[Ok Duration Agent Report].freeze

  # Indented result table lines for [label, ok, detail, elapsed] results:
  # a heading row, then one row per result, with ✓ and the report filename
  # on success, ✗ and the error in parentheses on failure.
  module_function def format_result_table(results)
    rows = results.map do |label, ok, detail, elapsed|
      [ok ? '✓' : '✗', format_duration(elapsed), label, ok ? detail : "(#{detail})"]
    end
    table = [RESULT_HEADINGS, *rows]
    # The last column is left unpadded, so lines have no trailing spaces.
    widths = table.transpose[0...-1].map { |column| column.map { |cell| display_width(cell) }.max }
    table.map do |row|
      cells = row[0...-1].zip(widths).map { |cell, width| cell + (' ' * (width - display_width(cell))) }
      "  #{[*cells, row.last].join('  ')}"
    end
  end

  # East Asian wide and fullwidth characters (CJK, Hangul, fullwidth forms,
  # most emoji), which terminals show two columns wide.
  WIDE_CHAR = Regexp.new(
    '[\u1100-\u115F\u2E80-\u303E\u3041-\u33FF\u3400-\u4DBF\u4E00-\u9FFF' \
    '\uA000-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE30-\uFE4F\uFF00-\uFF60' \
    '\uFFE0-\uFFE6\u{1F300}-\u{1F64F}\u{1F900}-\u{1F9FF}\u{20000}-\u{3FFFD}]'
  )
  # Combining marks and zero-width characters, which take no column.
  ZERO_WIDTH_CHAR = /[\p{Mn}\p{Me}\u200B-\u200F\uFEFF]/

  # The number of terminal columns text takes: as String#length, but
  # counting wide characters as two and zero-width ones as none.
  # Approximate (e.g. ambiguous-width characters count as one), but enough
  # to keep result tables aligned.
  module_function def display_width(text)
    text.length + text.scan(WIDE_CHAR).size - text.scan(ZERO_WIDTH_CHAR).size
  end

  # Prints the "--- Consolidation complete ---" (or error) marker.
  module_function def puts_consolidation_status(ok)
    puts "\n--- Consolidation #{ok ? 'complete' : 'error'} ---"
  end

  # True if a config entry (agent or consolidator) has the required string
  # 'provider' and 'model' fields.
  module_function def valid_agent_entry?(entry)
    entry.is_a?(Hash) && entry['provider'].is_a?(String) && entry['model'].is_a?(String)
  end

  # True if `name` (a bare command name) is an executable file in a PATH
  # directory. Checked up front so a missing harness fails before any run
  # dir is created, rather than as an Errno::ENOENT from every agent. An
  # empty PATH entry means the current directory, as it does for execvp (-1
  # keeps a trailing empty entry).
  module_function def executable_on_path?(name)
    ENV.fetch('PATH', '').split(File::PATH_SEPARATOR, -1).map { |dir| dir.empty? ? '.' : dir }.any? do |dir|
      path = File.join(dir, name)
      File.executable?(path) && !File.directory?(path)
    end
  end

  # "harness / provider / model" for a validated config entry, printed at
  # startup so it is clear which agents are still running later.
  module_function def agent_descriptor(entry)
    "#{HARNESS::NAME} / #{entry['provider']} / #{entry['model']}"
  end

  # AGENT_COUNCIL_OPTS as UTF-8, or nil when unset. Retagged because ENV
  # values carry the locale's encoding (binary under LANG=C), which would let
  # invalid bytes through unchecked.
  module_function def env_options_value(env = ENV)
    env[ENV_OPTS_VAR]&.dup&.force_encoding(Encoding::UTF_8)
  end

  # Shell-split tokens from AGENT_COUNCIL_OPTS, or [] when unset.
  module_function def env_options(env = ENV)
    raw = env_options_value(env)
    return [] if raw.nil? || raw.strip.empty?

    Shellwords.shellsplit(raw)
  rescue ArgumentError, EncodingError => e # e.g. an unclosed quote, invalid UTF-8
    raise ArgumentError, "Invalid #{ENV_OPTS_VAR} value: #{e.message}"
  end

  # options: receives the parsed option values (:consolidate, :output_dir).
  # env: where -h finds the current AGENT_COUNCIL_OPTS value.
  module_function def option_parser(options = {}, env = ENV)
    OptionParser.new do |opts|
      opts.banner = <<~BANNER
        -------------------------------------------------------------------------------
        Usage:                 agent-council [options] PROMPT_FILE [CONFIG_FILE]
                               agent-council --consolidate RUN_DIR
        Repository:            https://github.com/keithrbennett/agent-council
        Documentation (Local): #{File.join(PROJECT_ROOT, 'README.md')}
        Examples (Local):      #{EXAMPLES_DIR}
        Version:               #{VERSION}
        -------------------------------------------------------------------------------

        Arguments:
          PROMPT_FILE   Path to the prompt file to send to every configured model (required)
          CONFIG_FILE   Path to a YAML agent config (default: ./#{CWD_CONFIG_NAME}, else ~/#{HOME_CONFIG_NAME}; required if neither exists)
          RUN_DIR       With --consolidate, a finished run's directory (no PROMPT_FILE or CONFIG_FILE)

        Agents analyze the current directory: run from the project to be analyzed.

        Options:
      BANNER

      opts.on('--consolidate RUN_DIR',
        'Consolidate an existing run\'s reports, in place; runs no analysts') do |dir|
        options[:consolidate] = dir
      end

      opts.on('-o', '--output-dir DIR',
        'Base directory for run dirs, as DIR/<date>/<time>',
        "(default: ./#{DEFAULT_REPORTS_DIR_NAME})",
        'Not allowed with --consolidate') do |dir|
        options[:output_dir] = dir
      end

      opts.on('-h', '--help', 'Show this help and exit') do
        puts opts
        exit 0
      end

      opts.on('-v', '--version', 'Show the version and exit') do
        puts "agent-council #{VERSION}"
        exit 0
      end

      opts.separator ''
      opts.separator 'Environment:'
      opts.separator "  #{ENV_OPTS_VAR} holds arguments inserted before the command-line ones,"
      opts.separator '  so an option given on the command line overrides the same option there.'
      opts.separator "  Example: export #{ENV_OPTS_VAR}=\"--output-dir tmp/council\""
      # Inspected, so newlines can't break -h. (A value with invalid bytes
      # never gets here: env_options rejects it first.)
      env_value = env_options_value(env).to_s
      opts.separator "  Currently set to: #{env_value.inspect}" unless env_value.strip.empty?
      opts.separator ''
      opts.separator 'Examples:'
      opts.separator '  agent-council my-analysis-prompt.md'
      opts.separator '  agent-council my-analysis-prompt.md other-config.yml'
      opts.separator '  agent-council -o tmp/council my-analysis-prompt.md'
      opts.separator "  agent-council --consolidate #{DEFAULT_REPORTS_DIR_NAME}/2026-09-03/09-14-02"
    end
  end

  module_function def main(argv)
    abort_if_native_windows
    options = {}
    parser = option_parser(options)
    begin
      argv = parser.parse(env_options + argv)
    rescue ArgumentError => e # a malformed AGENT_COUNCIL_OPTS
      abort e.message
    rescue OptionParser::ParseError => e
      warn e.message
      warn parser
      exit 1
    end

    if options[:consolidate]
      unless argv.empty?
        warn parser
        exit 1
      end
      # The consolidation report goes into RUN_DIR itself.
      if options.key?(:output_dir)
        abort "--output-dir (given directly or in #{ENV_OPTS_VAR}) cannot be used with --consolidate, " \
          'which writes into RUN_DIR'
      end
      consolidate_run(options[:consolidate])
    end

    # Checked up front, so a bad value fails before any work, with a message
    # rather than a backtrace. A blank value (e.g. -o "$UNSET_VAR") would
    # otherwise resolve to the cwd and scatter day dirs over the project.
    if options[:output_dir]&.strip&.empty?
      abort '--output-dir needs a directory; got an empty value'
    end
    reports_root =
      begin
        reports_dir(options[:output_dir])
      rescue ArgumentError => e # e.g. ~nosuchuser/x
        abort "Invalid --output-dir #{options[:output_dir]}: #{e.message}"
      end
    # mkdir_p would fail on a file anywhere along the path, so check the
    # nearest part that exists, which is the dir itself if it exists.
    existing = reports_root
    existing = File.dirname(existing) until File.exist?(existing)
    unless File.directory?(existing)
      abort "Output dir #{relative_path(reports_root)} can't be created: " \
        "#{relative_path(existing)} is not a directory"
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
        Minimal config: agents: [{provider: ..., model: ...}]
        Sample configs: #{File.join(EXAMPLES_DIR, 'configs')}
      MESSAGE
    end
    abort "Config file not found: #{config_path}" unless File.file?(config_path)

    # Read once. Analysts receive the user's prompt followed by the
    # report-format addendum (see compose_analyst_prompt); the consolidator
    # cites the prompt alone.
    # The prompt and analyst_format.md are copied into the run dir, so the
    # exact bytes sent to each analyst are recoverable.
    prompt = File.read(prompt_path, encoding: ENCODING)
    abort "Prompt file is empty: #{prompt_path}" if prompt.empty?
    abort "Analyst format addendum missing: #{ANALYST_FORMAT_PATH}" unless File.file?(ANALYST_FORMAT_PATH)
    # All three are copied into the run dir under their own names, so a
    # shared name would leave one copy in place of another.
    copied_paths = { 'prompt' => prompt_path, 'config' => config_path, 'addendum' => ANALYST_FORMAT_PATH }
    copied_names = copied_paths.transform_values { |path| File.basename(path) }
    unless copied_names.values.uniq.size == copied_names.size
      abort "The prompt, config and #{File.basename(ANALYST_FORMAT_PATH)} need different file names, " \
        'since all three are copied into the run dir: ' \
        "#{copied_names.map { |role, name| "#{role} #{name}" }.join(', ')}"
    end
    if (role = copied_names.key(REVIEWS_DIR_NAME))
      abort "The #{role} can't be named #{REVIEWS_DIR_NAME}, the run dir's subdirectory for analyst reports"
    end
    analyst_prompt = compose_analyst_prompt(prompt, File.read(ANALYST_FORMAT_PATH, encoding: ENCODING))

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

    abort_unless_harness_installed

    # One run dir per invocation, day-bucketed so the reports dir stays
    # navigable at volume: <reports dir>/<yyyy-mm-dd>/<hh-mm-ss>/. The dir name is pure time
    # (plus a collision suffix, see claim_run_dir); full timestamp and query
    # slug go into the report filenames (file_prefix).
    now = Time.now
    day = now.strftime('%Y-%m-%d')
    day_dir = File.join(reports_root, day)
    run_name =
      begin
        claim_run_dir(day_dir, now.strftime('%H-%M-%S'))
      rescue SystemCallError => e # e.g. no write permission
        abort "Cannot create a run dir under #{relative_path(reports_root)}: #{e.message}"
      end
    run_stamp = "#{day}-#{run_name}"
    iso_stamp = iso_timestamp(now)
    slug = query_slug(prompt_path)
    file_prefix = "#{run_stamp}_#{slug}"
    # prompt_file and config_file name the input copies in the run dir, and
    # run_stamp gives the report filenames' prefix, so --consolidate needn't
    # rely on the run dir's path.
    report_meta = { 'role' => 'analyst', 'timestamp' => iso_stamp, 'query' => slug,
      'prompt_file' => File.basename(prompt_path), 'config_file' => File.basename(config_path),
      'config_source' => display_source_path(config_path), 'run_stamp' => run_stamp }
    run_dir = File.join(day_dir, run_name)
    reviews_dir = File.join(run_dir, REVIEWS_DIR_NAME)
    FileUtils.mkdir_p(reviews_dir)

    # Keep the run's inputs recoverable: copy the prompt, format
    # addendum, and config. (The orchestrator is not copied: it is
    # versioned in git.)
    FileUtils.cp(prompt_path, run_dir)
    FileUtils.cp(ANALYST_FORMAT_PATH, run_dir)
    FileUtils.cp(config_path, run_dir)

    # A default config's path is absolute (resolve_config_path makes it
    # so), to show which of the defaults was picked up.
    puts
    puts(argv[1] ? "Config:  #{relative_path(config_path)}" : "Config:  [default] #{config_path}")
    puts "Prompt:  #{relative_path(prompt_path)}"
    puts "Run Dir: #{relative_path(run_dir)}"
    puts "\nReview Agents (#{agents.size}):"
    agents.each_with_index do |agent, i|
      puts "  ##{i + 1} #{agent_descriptor(agent)}"
    end
    puts "\nConsolidator Agent:\n  #{agent_descriptor(consolidator)}" if consolidator
    puts "\nReview Progress:"
    pool = WorkerPool.new(grace: INTERRUPT_GRACE_SECONDS)
    pool.trap_signals
    agents.each_with_index do |agent, i|
      index = i + 1
      pool.start do
        provider = agent.is_a?(Hash) ? agent['provider'] : nil
        model = agent.is_a?(Hash) ? agent['model'] : nil
        meta = report_meta.merge('agent_index' => index)
        (label, ok, detail), elapsed = timed do
          run_agent(agent, analyst_prompt, reviews_dir, file_prefix,
            index:  index,
            meta:   meta,
            header: ->(duration) { byline_table(meta.merge('duration' => duration), provider, model) },
            pool:   pool)
        end
        [label, ok, detail, elapsed]
      end
    end
    results = pool.collect do |label, ok, detail, elapsed|
      duration = format_duration(elapsed)
      puts(ok ? "  ✓ #{duration}  #{label}" : "  ✗ #{duration}  #{label}  (#{detail})")
    end

    failed = results.count { |_, ok, _| !ok }
    puts "\nReviews (in #{relative_path(reviews_dir)}):"
    puts format_result_table(results)
    puts "\n--- Reviews complete (#{results.size - failed}/#{results.size} succeeded) ---"

    if consolidator
      puts "\nConsolidation Report (in #{relative_path(run_dir)}):"
      failures = results.reject { |_, ok, _| ok }.map { |label, _, detail, _| [label, detail] }
      pool.start do
        timed do
          run_consolidation(consolidator, prompt, run_dir, file_prefix,
            meta: report_meta, prompt_path: prompt_path, failures: failures, pool: pool)
        end
      end
      (label, ok, detail), elapsed = pool.collect.first
      puts format_result_table([[label, ok, detail, elapsed]])
      puts_consolidation_status(ok)
    end

    exit(failed.zero? ? 0 : 1)
  rescue Interrupt
    exit_interrupted(pool)
  end

  # --consolidate RUN_DIR: runs the consolidator over an existing
  # run's reports, writing its report into that run dir. The prompt,
  # config, and run's identity (timestamp, query, run_stamp) all come from
  # the run itself: its analysts' front matter names the prompt and config
  # copies.
  # The consolidator is the config copy's; edit that copy to try another.
  # Exits 0 only if the consolidation succeeded.
  module_function def consolidate_run(run_dir)
    abort "Run dir not found: #{run_dir}" unless File.directory?(run_dir)
    reviews_dir = File.join(run_dir, REVIEWS_DIR_NAME)
    reports = File.directory?(reviews_dir) ? collect_reports(reviews_dir) : []
    abort "No analyst reports found in #{reviews_dir}" if reports.empty?

    # From the first report that has them, so one stray or older report in
    # reviews/ doesn't block the run.
    fields = reports.map { |report| report[2] }
      .find { |f| f.values_at('prompt_file', 'config_file', 'run_stamp', 'query').all? }
    unless fields
      abort "Reports in #{reviews_dir} lack prompt_file, config_file, run_stamp or query; " \
        'runs made before --consolidate existed cannot be consolidated'
    end
    %w[prompt_file config_file].each do |key|
      abort "Invalid #{key} in #{reviews_dir}: #{fields[key].inspect}" unless bare_name?(fields[key])
    end
    prompt_path = File.join(run_dir, fields['prompt_file'])
    config_path = File.join(run_dir, fields['config_file'])
    abort "Prompt copy not found: #{prompt_path}" unless File.file?(prompt_path)
    abort "Config copy not found: #{config_path}" unless File.file?(config_path)

    config =
      begin
        YAML.safe_load_file(config_path)
      rescue Psych::Exception => e
        abort "Invalid YAML in #{config_path}: #{e.message}"
      end
    consolidator = config['consolidator'] if config.is_a?(Hash)
    abort "No consolidator in #{config_path}; add one to consolidate" unless consolidator
    unless valid_agent_entry?(consolidator)
      abort "Consolidator in #{config_path} needs string 'provider' and 'model' fields"
    end
    unless File.file?(CONSOLIDATE_PROMPT_PATH)
      abort "Consolidation template missing: #{CONSOLIDATE_PROMPT_PATH}"
    end

    file_prefix = "#{fields['run_stamp']}_#{fields['query']}" # as in a normal run
    filename = consolidated_filename(file_prefix, consolidator['provider'], consolidator['model'])
    unless bare_name?(filename)
      abort "Invalid run_stamp or query in #{reviews_dir}: #{fields.values_at('run_stamp', 'query').inspect}"
    end
    if File.exist?(File.join(run_dir, filename))
      abort "Consolidated report already exists: #{relative_path(File.join(run_dir, filename))}\n" \
        'Rename or delete it to consolidate again with the same model configuration.'
    end
    prompt = File.read(prompt_path, encoding: ENCODING)
    abort "Prompt copy is empty: #{prompt_path}" if prompt.empty?

    abort_unless_harness_installed

    # In the same key order as a normal run's front matter.
    meta = fields.slice('role', 'timestamp', 'query', 'prompt_file', 'config_file', 'config_source',
      'run_stamp')
    meta['timestamp'] = iso_timestamp(meta['timestamp']) if meta['timestamp'].is_a?(Time)

    puts "Config:  #{relative_path(config_path)}"
    puts "Prompt:  #{relative_path(prompt_path)}"
    puts "Run Dir: #{relative_path(run_dir)}"
    puts "\nConsolidator Agent:\n  #{agent_descriptor(consolidator)}"
    puts "\nConsolidation Report (in #{relative_path(run_dir)}, " \
      "from #{reports.size} review#{'s' unless reports.size == 1}):"
    failures = missing_agents(config, reports)
    pool = WorkerPool.new(grace: INTERRUPT_GRACE_SECONDS)
    pool.trap_signals
    pool.start do
      timed do
        run_consolidation(consolidator, prompt, run_dir, file_prefix,
          meta: meta, prompt_path: relative_path(prompt_path), failures: failures, pool: pool)
      end
    end
    (label, ok, detail), elapsed = pool.collect.first
    puts format_result_table([[label, ok, detail, elapsed]])
    puts_consolidation_status(ok)
    exit(ok ? 0 : 1)
  rescue Interrupt
    exit_interrupted(pool)
  end

  # True if name is a plain file name: no directory part or null byte, and
  # not empty, "." or "..".
  # Applied to every front matter value that becomes part of a path, so a
  # crafted report can't make --consolidate read or write outside the run
  # dir.
  module_function def bare_name?(name)
    name.is_a?(String) && !name.include?("\0") && !['', '.', '..'].include?(name) &&
      File.basename(name) == name
  end

  # What --consolidate tells the consolidator about an agent without a report.
  MISSING_REPORT_REASON =
    'reason not recorded (it may have failed, been interrupted, or had its report removed)'

  # For --consolidate: the config copy's agents that have no report, as
  # [label, reason] pairs. Why wasn't recorded, and needn't be a failure:
  # the run may have been interrupted, or a report removed.
  module_function def missing_agents(config, reports)
    agents = config['agents'].is_a?(Array) ? config['agents'] : []
    present = reports.map(&:first)
    agents.each_with_index.filter_map do |agent, i|
      next unless valid_agent_entry?(agent)

      label = agent_label(agent['provider'], agent['model'], i + 1)
      [label, MISSING_REPORT_REASON] unless present.include?(label)
    end
  end

  # Checked up front, before any run dir is created or model called.
  module_function def abort_unless_harness_installed
    return if executable_on_path?(HARNESS::NAME)

    abort <<~MESSAGE
      #{HARNESS::NAME} executable not found; is `#{HARNESS::NAME}` installed and on your PATH?
      See "Prerequisites" in #{File.join(PROJECT_ROOT, 'README.md')}
    MESSAGE
  end

  # After Ctrl-C (or another signal WorkerPool#trap_signals traps):
  # stops pool's agents, if any, and dies by the signal.
  module_function def exit_interrupted(pool)
    report = -> do
      warn "\nInterrupted."
    rescue IOError, SystemCallError
      nil # e.g. the terminal hung up
    end
    if pool
      pool.shutdown(&report)
      pool.exit_by_signal
    else # before any agent started; only a Ctrl-C can get here
      report.call
      WorkerPool.exit_by_signal('INT')
    end
  end
end
