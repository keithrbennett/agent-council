# frozen_string_literal: true

require 'English'
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
  # Release notes on main cover every version, including ones newer than
  # the installed gem, which is what someone deciding whether to upgrade
  # needs. The installed gem also ships its own RELEASE_NOTES.md.
  spec.metadata['changelog_uri'] = 'https://github.com/keithrbennett/agent-council/blob/main/RELEASE_NOTES.md'
  # Documentation for this exact version: the v<VERSION> tag that
  # `rake release` creates, not main, which may describe a different version.
  spec.metadata['documentation_uri'] = "https://github.com/keithrbennett/agent-council/tree/v#{spec.version}"
  spec.metadata['bug_tracker_uri'] = 'https://github.com/keithrbennett/agent-council/issues'
  spec.required_ruby_version = '>= 3.2'

  # Ship runtime assets (lib/ includes code plus the prompt templates under
  # lib/agent_council/templates/), user-facing documentation, and the small
  # sample prompts and configs, so installed users can read docs and run
  # examples matching their installed version. Exclude development-only
  # files (CI config, lint configs, Gemfile, lockfile, Rakefile, spec/,
  # REVIEW_NOTES.md, CONTRIBUTING.md, etc.) and generated sample output
  # (examples/results/).
  # Only git-tracked files are packaged, so untracked local files (personal
  # configs, editor backups) can't leak into the gem. Without FNM_DOTMATCH,
  # the patterns skip dotfiles.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    patterns = %w[
      lib/**/* exe/* examples/prompts/*.md examples/configs/*.yml
      README.md RELEASE_NOTES.md LICENSE.txt DESIGN.md code-review-agents.md
    ]
    tracked = `git ls-files -z`
    # Outside a git checkout this would otherwise build a gem with no files.
    # Bundler evaluates this gemspec too (the Gemfile's `gemspec`), so
    # `bundle install` and `bundle exec` also need a git checkout.
    raise '`git ls-files` failed; build the gem from a git checkout' unless $CHILD_STATUS.success?
    raise '`git ls-files` listed no files; commit or add them before building' if tracked.empty?

    tracked.split("\x0").select do |f|
      patterns.any? { |p| File.fnmatch?(p, f, File::FNM_PATHNAME) }
    end
  end
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # No runtime dependencies: the tool itself uses only the Ruby standard
  # library. It does require the external
  # `pi` CLI at runtime, but that is not a Ruby gem dependency.
  spec.metadata['rubygems_mfa_required'] = 'true'
end
