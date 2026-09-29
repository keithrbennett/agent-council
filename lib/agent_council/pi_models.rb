# frozen_string_literal: true

require 'json'
require 'open3'

module AgentCouncil
  # Reads and formats the models configured in pi.
  module PiModels
    FIELD_NAMES = {
      provider:       'provider',
      id:             'id',
      name:           'name',
      api:            'api',
      reasoning:      'reasoning',
      context_window: 'contextWindow',
      max_tokens:     'maxTokens',
    }.freeze

    Model = Data.define(*FIELD_NAMES.keys) do
      def self.from_hash(raw)
        missing = FIELD_NAMES.values - raw.keys
        raise ArgumentError, "missing model field(s): #{missing.join(', ')}" unless missing.empty?

        new(**FIELD_NAMES.to_h { |member, field| [member, raw[field]] })
      end

      # Keep pi's JSON field names in --json output while exposing Ruby-style
      # accessors to callers.
      def to_h
        FIELD_NAMES.to_h { |member, field| [field, public_send(member)] }
      end
    end

    # Raised for failures talking to pi (missing executable, early exit, RPC error).
    class Error < RuntimeError; end

    RPC_GET_MODELS = { 'type' => 'get_available_models' }.freeze
    RPC_REQUEST_ID = 'list-models'

    module_function def fetch_models
      Open3.popen3('pi', '--mode', 'rpc', '--no-session') do |stdin, stdout, stderr, wait_thr|
        # Drain stderr concurrently so a chatty pi can't block on a full pipe,
        # and so we can report it if pi fails.
        stderr_reader = Thread.new { stderr.read }
        begin
          send_rpc_command(stdin, RPC_GET_MODELS.merge('id' => RPC_REQUEST_ID))
        rescue Errno::EPIPE, IOError
          # pi exited (or closed stdin) before we could send the request; fall
          # through so the exit-status/diagnostics check below explains why.
        end

        events = stdout.each_line(chomp: true).lazy.filter_map { |line| parse_event(line) }
        response = events.detect { |event| event['id'] == RPC_REQUEST_ID && event['type'] == 'response' }
        return event_to_models(response) if response

        diagnostics = stderr_reader.value.to_s.strip
        message = "pi exited (#{describe_status(wait_thr.value)}) before responding"
        message += ": #{diagnostics}" unless diagnostics.empty?
        raise Error, message
      ensure
        stderr_reader&.kill
      end
    rescue Errno::ENOENT
      raise Error, 'pi executable not found; is `pi` installed and on your PATH?'
    rescue SystemCallError => e
      # Covers EACCES (not executable) and other spawn-time failures that
      # Errno::ENOENT doesn't catch.
      raise Error, "pi could not be started: #{e.message}"
    end

    # Describes a Process::Status for diagnostics, covering both normal exits
    # and termination by signal (where #exitstatus is nil).
    module_function def describe_status(status)
      return "signal #{status.termsig}" if status.signaled?

      status.exitstatus.to_s
    end

    # Returns the parsed event, or nil for lines that aren't JSON objects
    # (blank lines, stray non-protocol output).
    module_function def parse_event(line)
      event = JSON.parse(line)
      event if event.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    module_function def send_rpc_command(stdin, command)
      stdin.sync = true
      stdin.puts(JSON.generate(command))
      stdin.close
    end

    module_function def event_to_models(event)
      raise Error, "pi error: #{event['error']}" unless event['success']

      raw_models = event.dig('data', 'models')
      raise Error, "pi response missing data.models: #{event.inspect}" unless raw_models.is_a?(Array)

      raw_models.map do |raw_model|
        Model.from_hash(raw_model)
      rescue ArgumentError => e
        raise Error, "pi returned a malformed model: #{e.message}"
      end
    end

    module_function def help_text
      <<~HELP
        Usage: pi-models [options]

        List provider/model pairs available to `pi`.

        Options:
          -t, --table     Formatted table (default)
          -j, --json      Pretty-printed JSON array of model hashes
          -i, --ids       One "provider/id" per line (shell-friendly)
          -h, --help      Show this help and exit

        Examples:
          pi-models
          pi-models --json | jq '.[0]'
          pi-models --ids | head -5
          pi-models --table            # explicit default
      HELP
    end

    module_function def format_as_table(models)
      return "No models configured. Run `pi` interactively and add a provider first.\n" if models.empty?

      columns = [
        { label: 'PROVIDER',   value: ->(model) { model.provider.to_s },              align: :left  },
        { label: 'MODEL ID',   value: ->(model) { model.id.to_s },                    align: :left  },
        { label: 'API',        value: ->(model) { model.api.to_s },                   align: :left  },
        { label: 'REASONING',  value: ->(model) { model.reasoning ? 'yes' : 'no' }, align: :left  },
        { label: 'CONTEXT',    value: ->(model) { model.context_window.to_s },      align: :right },
        { label: 'MAX TOKENS', value: ->(model) { model.max_tokens.to_s },          align: :right },
        { label: 'NAME',       value: ->(model) { model.name.to_s },                  align: :left  },
      ]

      widths = columns.map do |column|
        max_value_length = models.map { |model| column[:value].(model).length }.max
        [max_value_length, column[:label].length].max
      end

      last_index = columns.length - 1
      format_string = columns.each_with_index.map do |column, index|
        # Don't pad the final left-aligned column; it would only add trailing whitespace.
        next '%s' if index == last_index && column[:align] == :left

        align_sign = column[:align] == :right ? '' : '-'
        "%#{align_sign}#{widths[index]}s"
      end.join('  ') + "\n"

      separator = widths.map { |width| '-' * width }.join('  ') + "\n"
      header = format(format_string, *columns.map { |column| column[:label] })
      body_lines = models.map do |model|
        format(format_string, *columns.map do |column|
          column[:value].(model)
        end)
      end

      separator + header + separator + body_lines.join + separator
    end

    module_function def format_as_json(models)
      JSON.pretty_generate(models.map(&:to_h)) + "\n"
    end

    module_function def format_as_ids(models)
      models.map { |model| "#{model.provider}/#{model.id}" }.join("\n") + "\n"
    end
  end
end
