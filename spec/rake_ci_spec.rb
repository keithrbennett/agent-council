# frozen_string_literal: true

# Runs the Rakefile's ci task against a fake `gh`, first on PATH, which
# records each call's arguments, one line per call, in the file GH_ARGS
# names, answers `gh run list` with the RUNS environment variable, and
# answers `gh run view --log-failed` as LOG says: "ok" prints a log,
# "empty" prints nothing (as gh does for a cancelled run), and "fail"
# exits 1.
require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

RSpec.describe 'rake ci' do
  let(:project_root) { File.expand_path('..', __dir__) }
  let(:bin_dir) { Dir.mktmpdir('agent-council-rake-ci') }
  let(:gh_args_path) { File.join(bin_dir, 'gh_args.txt') }
  let(:head_sha) { `git -C #{project_root} rev-parse HEAD`.strip }
  let(:gh_calls) { File.readlines(gh_args_path, chomp: true) }

  before do
    File.write(File.join(bin_dir, 'gh'), <<~SH)
      #!/bin/sh
      echo "$*" >> "$GH_ARGS"
      if [ "$1 $2" = "run view" ]; then
        case "$LOG" in
          fail) echo "log not found" >&2; exit 1 ;;
          empty) exit 0 ;;
          *) echo "log of run $3"; exit 0 ;;
        esac
      fi
      printf '%s' "$RUNS"
    SH
    File.chmod(0o755, File.join(bin_dir, 'gh'))
  end

  after { FileUtils.rm_rf(bin_dir) }

  def run(id, workflow, conclusion, event: 'push', status: 'completed', created: '2026-01-01T00:00:00Z')
    { 'databaseId' => id, 'workflowName' => workflow, 'event' => event, 'status' => status,
      'conclusion' => conclusion, 'url' => "https://example.test/runs/#{id}", 'createdAt' => created }
  end

  # [output (stdout and stderr together), exit status]
  def rake_ci(runs, log: 'ok')
    env = { 'PATH' => "#{bin_dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}",
            'RUNS' => JSON.generate(runs), 'LOG' => log, 'GH_ARGS' => gh_args_path }
    output, status = Open3.capture2e(env, RbConfig.ruby, Gem.bin_path('rake', 'rake'), 'ci',
      chdir: project_root)
    [output, status.exitstatus]
  end

  it 'passes when every run passed, showing one line per workflow and event' do
    output, status = rake_ci([run(1, 'CI', 'success'), run(2, 'Security', 'success')])
    expect(status).to eq(0), output
    expect(output).to match(%r{^  CI \(push\)\s+success\s+\S+/runs/1$})
      .and match(/^  Security \(push\)\s+success/)
  end

  it "asks gh for the runs of HEAD's full commit ID, with the fields it reads" do
    rake_ci([run(1, 'CI', 'success')])
    expect(gh_calls).to eq(["run list --commit #{head_sha} --limit 100 " \
      '--json databaseId,workflowName,event,status,conclusion,url,createdAt'])
  end

  it 'counts neutral and skipped runs as passing' do
    output, status = rake_ci([run(1, 'CI', 'neutral'), run(2, 'Security', 'skipped')])
    expect(status).to eq(0), output
  end

  it "judges each workflow by its newest run, so an older failure doesn't count" do
    output, status = rake_ci([run(1, 'CI', 'failure'),
      run(2, 'CI', 'success', created: '2026-01-02T00:00:00Z')])
    expect(status).to eq(0), output
    expect(output).to match(%r{^  CI \(push\)\s+success\s+\S+/runs/2$})
    expect(output).not_to include('runs/1')
  end

  it 'fails when a push run failed, though a later scheduled run of the workflow passed' do
    output, status = rake_ci([run(1, 'Security', 'failure'),
      run(2, 'Security', 'success', event: 'schedule', created: '2026-01-02T00:00:00Z')])
    expect(status).to eq(1)
    expect(output).to include("Security (push) failed jobs' logs:", 'log of run 1', 'Failed: Security (push)')
    expect(gh_calls.last).to eq('run view 1 --log-failed')
  end

  it 'fails a cancelled run, pointing to it when gh shows no failed job logs' do
    output, status = rake_ci([run(1, 'CI', 'cancelled')], log: 'empty')
    expect(status).to eq(1)
    expect(output).to include('CI (push): no failed job logs to show', 'https://example.test/runs/1',
      'Failed: CI (push)')
  end

  it 'names both the failed and the unfinished runs, pointing to a run whose logs gh cannot fetch' do
    output, status = rake_ci([run(1, 'CI', 'failure'), run(2, 'Security', nil, status: 'in_progress')],
      log: 'fail')
    expect(status).to eq(1)
    expect(output).to include('CI (push): no failed job logs to show', 'Failed: CI (push)',
      'Not finished: Security (push)')
  end

  it 'fails, saying why there may be none, when the commit has no runs' do
    output, status = rake_ci([])
    expect(status).to eq(1)
    expect(output).to include('No runs for this commit')
  end

  it 'reports a completed run with no conclusion (which gh gives as "") as unknown, and not a pass' do
    output, status = rake_ci([run(1, 'CI', '')])
    expect(status).to eq(1)
    expect(output).to match(/^  CI \(push\)\s+unknown/).and include('Failed: CI (push)')
  end
end
