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
        new(**FIELD_NAMES.to_h { |member, field| [member, raw.fetch(field)] })
      end

      # Keep pi's JSON field names in --json output while exposing Ruby-style
      # accessors to callers.
      def to_h
        FIELD_NAMES.to_h { |member, field| [field, public_send(member)] }
      end
    end

    RPC_GET_MODELS = { 'type' => 'get_available_models' }.freeze
    RPC_REQUEST_ID = 'list-models'

    module_function def fetch_models
      Open3.popen3('pi', '--mode', 'rpc', '--no-session') do |stdin, stdout, _stderr, wait_thr|
        send_rpc_command(stdin, RPC_GET_MODELS.merge('id' => RPC_REQUEST_ID))

        events = stdout.each_line(chomp: true).map { |line| JSON.parse(line) }
        response = events.detect { |event| event['id'] == RPC_REQUEST_ID && event['type'] == 'response' }
        return event_to_models(response) if response

        raise "pi exited (#{wait_thr.value.exitstatus}) before responding"
      end
    end

    module_function def send_rpc_command(stdin, command)
      stdin.sync = true
      stdin.puts(JSON.generate(command))
      stdin.close
    end

    module_function def event_to_models(event)
      if event['success']
        event.dig('data', 'models').map { |model| Model.from_hash(model) }
      else
        raise "pi error: #{event['error']}"
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
        { label: 'PROVIDER',   value: ->(model) { model.provider },                 align: :left  },
        { label: 'MODEL ID',   value: ->(model) { model.id },                       align: :left  },
        { label: 'API',        value: ->(model) { model.api },                      align: :left  },
        { label: 'REASONING',  value: ->(model) { model.reasoning ? 'yes' : 'no' }, align: :left  },
        { label: 'CONTEXT',    value: ->(model) { model.context_window.to_s },      align: :right },
        { label: 'MAX TOKENS', value: ->(model) { model.max_tokens.to_s },          align: :right },
        { label: 'NAME',       value: ->(model) { model.name },                     align: :left  },
      ]

      widths = columns.map do |column|
        max_value_length = models.map { |model| column[:value].(model).length }.max
        [max_value_length, column[:label].length].max
      end

      format_string = columns.each_with_index.map do |column, index|
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
