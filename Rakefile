# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

task default: :spec

namespace :security do
  desc 'Audit dependencies for vulnerabilities with bundler-audit'
  task :bundler_audit do
    sh 'bundle exec bundle audit check --update'
  end

  desc 'Audit Ruby and RubyGems for known vulnerabilities with ruby_audit'
  task :ruby_audit do
    sh 'bundle exec ruby-audit check'
  end

  task :all do
    failures = []

    begin
      Rake::Task['security:bundler_audit'].invoke
    rescue => e
      failures << "bundler-audit failed: #{e.message}"
    end

    begin
      Rake::Task['security:ruby_audit'].invoke
    rescue => e
      failures << "ruby-audit failed: #{e.message}"
    end

    if failures.empty?
      puts '--- Security audits completed successfully ---'
      next
    end

    failures.each { |message| warn message }
    abort 'Security audits failed'
  end
end

desc 'Run all security audits'
task security: 'security:all'

# One line per workflow and event (push, pull_request, schedule), since
# the newest run alone would let the Security workflow's quick success, or
# a later scheduled run's, hide a failure.
desc "Show the CI status of HEAD's commit, with the logs of any failed jobs"
task :ci do
  require 'json'
  require 'open3'
  $stdout.sync = true # keeps output in order with abort's, on stderr

  gh = ->(*args) do
    out, err, status = Open3.capture3('gh', *args)
    abort "gh #{args.first(2).join(' ')} failed: #{err.strip}" unless status.success?
    out
  rescue Errno::ENOENT
    abort 'rake ci needs the GitHub CLI, gh: https://cli.github.com/'
  end

  sha, status = Open3.capture2('git', 'rev-parse', 'HEAD')
  abort "Can't find HEAD's commit" unless status.success?
  sha = sha.strip
  puts "CI for #{`git log -1 --format='%h %s' #{sha}`.strip}"
  runs = JSON.parse(gh.call('run', 'list', '--commit', sha, '--limit', '100',
    '--json', 'databaseId,workflowName,event,status,conclusion,url,createdAt'))
  if runs.empty?
    abort "  No runs for this commit. Either it hasn't been pushed, GitHub hasn't\n  " \
      "started its runs yet, or it was never the head commit of a push or pull\n  " \
      'request to main, which is what the workflows run for.'
  end

  latest = runs.group_by { |run| run.values_at('workflowName', 'event') }
    .map { |_key, group| group.max_by { |run| run['createdAt'] } }
    .sort_by { |run| run.values_at('workflowName', 'event') }
  names = latest.to_h { |run| [run, "#{run['workflowName']} (#{run['event']})"] }
  states = latest.to_h do |run|
    # gh gives a missing conclusion as "", not null.
    conclusion = run['conclusion'].to_s.empty? ? 'unknown' : run['conclusion']
    [run, run['status'] == 'completed' ? conclusion : run['status']]
  end
  name_width = names.values.map(&:length).max
  state_width = states.values.map(&:length).max
  latest.each do |run|
    puts "  #{names[run].ljust(name_width)}  #{states[run].ljust(state_width)}  #{run['url']}"
  end

  # Only these pass; anything else, including a run in progress, doesn't.
  passing = %w[success neutral skipped]
  unfinished = latest.reject { |run| run['status'] == 'completed' }
  failed = latest.select { |run| run['status'] == 'completed' && !passing.include?(run['conclusion']) }
  failed.each do |run|
    log, _err, log_status = Open3.capture3('gh', 'run', 'view', run['databaseId'].to_s, '--log-failed')
    if log_status.success? && !log.strip.empty?
      puts "\n#{names[run]} failed jobs' logs:", log
    else
      puts "\n#{names[run]}: no failed job logs to show (an old gh may show none; see #{run['url']})"
    end
  end

  summary = []
  summary << "Failed: #{failed.map { |run| names[run] }.join(', ')}" unless failed.empty?
  summary << "Not finished: #{unfinished.map { |run| names[run] }.join(', ')}" unless unfinished.empty?
  abort "\n#{summary.join("\n")}" unless summary.empty?
end
