# frozen_string_literal: true

# The gemspec packages only git-tracked files, so it must refuse to build when
# git can't list them, rather than quietly producing a gem with no files.
require 'spec_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'

RSpec.describe 'agent-council.gemspec' do
  let(:project_root) { File.expand_path('..', __dir__) }
  let(:tmp_dir) { Dir.mktmpdir('agent-council-gemspec') }
  let(:gemspec) { File.join(tmp_dir, 'agent-council.gemspec') }

  around do |example|
    saved_env = ENV.to_h
    # Under a git hook (e.g. the pre-commit hook running rspec), git exports
    # GIT_DIR, GIT_INDEX_FILE, etc., which would point git in tmp_dir at
    # this checkout; clear every variable git treats as repository-local.
    `git rev-parse --local-env-vars`.split.each { |name| ENV.delete(name) }
    # Keep git from finding a repository above tmp_dir (e.g. a TMPDIR inside a checkout).
    ENV['GIT_CEILING_DIRECTORIES'] = File.dirname(tmp_dir)
    example.run
  ensure
    ENV.replace(saved_env)
    FileUtils.remove_entry(tmp_dir)
  end

  # A copy of the gemspec and the version file it requires, outside any checkout.
  before do
    FileUtils.cp(File.join(project_root, 'agent-council.gemspec'), gemspec)
    FileUtils.mkdir_p(File.join(tmp_dir, 'lib', 'agent_council'))
    FileUtils.cp(File.join(project_root, 'lib', 'agent_council', 'version.rb'),
      File.join(tmp_dir, 'lib', 'agent_council'))
  end

  # Gem::Specification.load reports the gemspec's exception as a warning and returns nil.
  def load_gemspec
    Gem::Specification.load(gemspec)
  end

  it 'fails to load outside a git checkout' do
    expect { expect(load_gemspec).to be_nil }
      .to output(/`git ls-files` failed; build the gem from a git checkout/).to_stderr_from_any_process
  end

  it 'fails to load when git tracks no files' do
    _out, err, status = Open3.capture3('git', 'init', '-q', tmp_dir)
    expect(status).to be_success, err

    expect { expect(load_gemspec).to be_nil }
      .to output(/`git ls-files` listed no files; commit or add them before building/)
      .to_stderr_from_any_process
  end
end
