# frozen_string_literal: true

require_relative 'lib/agent_council/version'

Gem::Specification.new do |spec|
  spec.name          = 'agent-council'
  spec.version       = AgentCouncil::VERSION
  spec.authors       = ['Keith R. Bennett']
  spec.email         = ['keithrbennett@gmail.com']

  spec.summary       = 'Run one analytical prompt through several AI models and save each ' \
    'response, with optional consolidation of all reports by another model'

  spec.description   = <<~DESCRIPTION.strip
    AgentCouncil runs the same prompt through multiple coding-agent
    harness/model instances (currently the pi harness) and saves each model's final
    response as a separate Markdown report. An optional consolidator model can then
    synthesize all the reports into one combined answer.
  DESCRIPTION
  spec.license       = 'MIT'

  spec.homepage      = 'https://github.com/keithrbennett/agent-council'
  spec.metadata['source_code_uri'] = 'https://github.com/keithrbennett/agent-council'
  spec.metadata['changelog_uri'] = 'https://github.com/keithrbennett/agent-council/blob/main/CHANGELOG.md'
  spec.required_ruby_version = '>= 3.2'

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`.split("\x0").reject do |f|
      f.start_with?('spec/')
    end
  end
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # No runtime dependencies: the tool itself uses only the Ruby standard
  # library (yaml, open3, fileutils, tmpdir). It does require the external
  # `pi` CLI at runtime, but that is not a Ruby gem dependency.
  spec.metadata['rubygems_mfa_required'] = 'true'
end
