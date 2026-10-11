# frozen_string_literal: true

# Smoke test: build the gem, install it into a throwaway GEM_HOME, and run the
# RubyGems-generated binstub. RubyGems `load`s the exe from a wrapper script, so
# this catches entry-point bugs (e.g. a `__FILE__ == $PROGRAM_NAME` guard that
# silently turns the installed command into a no-op) that running
# exe/agent-council from the checkout cannot.
require 'spec_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'

RSpec.describe 'installed agent-council binstub' do
  let(:project_root) { File.expand_path('..', __dir__) }
  let(:tmp_dir) { Dir.mktmpdir('agent-council-gem') }
  let(:gem_home) { File.join(tmp_dir, 'gems') }
  let(:gem_file) { File.join(tmp_dir, 'agent-council.gem') }

  after { FileUtils.remove_entry(tmp_dir) }

  def run_cmd(env, *cmd)
    # Isolate from the outer Bundler environment so gem/ruby behave as for an end user.
    Bundler.with_unbundled_env { Open3.capture3(env, *cmd, chdir: project_root) }
  end

  it 'runs AgentCouncil.main when invoked through the installed binstub' do
    _out, err, status = run_cmd({}, 'gem', 'build', 'agent-council.gemspec', '--output', gem_file)
    expect(status).to be_success, err

    env = { 'GEM_HOME' => gem_home, 'GEM_PATH' => gem_home }
    _out, err, status = run_cmd(env, 'gem', 'install', '--local', '--no-document', gem_file)
    expect(status).to be_success, err

    out, err, status = run_cmd(env, File.join(gem_home, 'bin', 'agent-council'), '--help')
    expect(status).to be_success, err
    expect(out).to include('Usage:', 'PROMPT_FILE')

    # The help text's local documentation and example paths exist in the installed gem.
    docs_path = out[/^Documentation \(Local\): (.+)$/, 1]
    examples_path = out[/^Examples \(Local\):\s+(.+)$/, 1]
    expect(docs_path).to start_with(gem_home)
    expect(examples_path).to start_with(gem_home)
    expect(File.file?(docs_path)).to be(true)
    expect(File.file?(File.join(examples_path, 'configs', 'single.yml'))).to be(true)
    expect(File.file?(File.join(examples_path, 'prompts', 'smoke-test_prompt.md'))).to be(true)
  end
end
