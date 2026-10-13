# frozen_string_literal: true

# End-to-end runs of exe/agent-council against a fake `pi`, mostly for Ctrl-C:
# SIGINT goes to agent-council's whole process group, as a terminal sends it.
# Agents run in process groups of their own, so they should get only the
# SIGTERM agent-council sends them; a fake pi that gets SIGINT records it.
# The fake pi's behavior is chosen by provider name:
# - done: answers at once with a report.
# - utf8: answers at once with a report containing non-ASCII text.
# - escaped: the same, but \u-escaped, so pi's output itself is ASCII.
# - dies: waits for SIGTERM, then writes into its TMPDIR as it exits (as
#   node does with its compile cache).
# - deaf: survives SIGTERM, so must be killed.
require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'

RSpec.describe 'agent-council end to end' do
  let(:project_root) { File.expand_path('..', __dir__) }
  let(:tmp_root) { Dir.mktmpdir('agent-council-e2e') }
  let(:bin_dir) { File.join(tmp_root, 'bin') }
  let(:work_dir) { File.join(tmp_root, 'work') }
  let(:child_tmp) { File.join(tmp_root, 'tmp') }
  let(:started_dir) { File.join(tmp_root, 'started') }
  let(:termed_dir) { File.join(tmp_root, 'termed') }
  let(:sigint_dir) { File.join(tmp_root, 'sigint') }
  let(:out_path) { File.join(tmp_root, 'out.txt') }
  let(:err_path) { File.join(tmp_root, 'err.txt') }
  let(:grace) { AgentCouncil::INTERRUPT_GRACE_SECONDS }
  let(:survivors) { [] } # filled in by run_council
  let(:exited_at) { [] } # filled in by run_council
  # No straight single quotes: the fake pi echoes it inside them.
  let(:non_ascii_answer) { 'Résumé ✓ “quoted”' }

  before do
    skip 'requires a POSIX shell and process groups' if Gem.win_platform?
    [bin_dir, work_dir, child_tmp, started_dir, termed_dir, sigint_dir].each { |dir| FileUtils.mkdir_p(dir) }
    File.write(File.join(work_dir, 'prompt.md'), "Question?\n")
    write_fake_pi
  end

  after { FileUtils.remove_entry(tmp_root) }

  def report_event(text)
    { type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: text }] } }
  end

  def write_fake_pi
    dying_writes = 'for i in $(seq 1 100); do mkdir -p "$TMPDIR/c/d$i"; touch "$TMPDIR/c/d$i/f"; done'
    fake_pi = File.join(bin_dir, 'pi')
    File.write(fake_pi, <<~SH)
      #!/usr/bin/env bash
      cat >/dev/null
      trap 'touch "#{sigint_dir}/$$"' INT
      case " $* " in
        *" --provider done "*) echo '#{JSON.generate(report_event('Answer.'))}'; exit 0 ;;
        *" --provider utf8 "*) echo '#{JSON.generate(report_event(non_ascii_answer))}'; exit 0 ;;
        *" --provider escaped "*) echo '#{JSON.generate(report_event(non_ascii_answer), ascii_only: true)}'; exit 0 ;;
        *" --provider dies "*) trap 'touch "#{termed_dir}/$$"; #{dying_writes}; exit 143' TERM ;;
        *" --provider deaf "*) trap 'touch "#{termed_dir}/$$"' TERM ;;
      esac
      touch "#{started_dir}/$$"
      # A foreground loop: a background job would ignore SIGINT and hold
      # agent-council's pipes open.
      while :; do sleep 0.1; done
    SH
    File.chmod(0o755, fake_pi)
  end

  def write_config(providers, consolidator: nil)
    agents = providers.map.with_index(1) { |provider, i| { 'provider' => provider, 'model' => "m#{i}" } }
    config = { 'agents' => agents }
    config['consolidator'] = { 'provider' => consolidator, 'model' => 'c' } if consolidator
    File.write(File.join(work_dir, 'config.yml'), YAML.dump(config))
  end

  def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def wait_until(timeout, what)
    deadline = monotonic_now + timeout
    until yield
      raise "timed out waiting for #{what}" if monotonic_now > deadline

      sleep 0.05
    end
  end

  # Runs agent-council in its own process group and returns its exit status.
  # With a block, waits until `started` fake agents are waiting, then yields
  # the group's pid for signalling. Afterwards, records in `survivors` the
  # fake agents still running once agent-council has exited, then kills
  # everything, so a regression fails the spec instead of hanging it. env:
  # extra child environment (a nil value unsets the variable).
  def run_council(started: 0, ignoring_hup: false, env: {})
    env = { 'PATH' => "#{bin_dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}", 'TMPDIR' => child_tmp, **env }
    exe = File.join(project_root, 'exe', 'agent-council')
    cmd = [RbConfig.ruby, '-I', File.join(project_root, 'lib'), exe, 'prompt.md', 'config.yml']
    cmd = ['sh', '-c', 'trap "" HUP; exec "$@"', 'sh', *cmd] if ignoring_hup # as nohup does
    pid = Process.spawn(env, *cmd, chdir: work_dir, pgroup: true, out: out_path, err: err_path)
    status = nil
    begin
      if block_given?
        wait_until(10, 'agents to start') { Dir.children(started_dir).size == started }
        yield pid
      end
      wait_until(15, 'agent-council to exit') { status = Process.wait2(pid, Process::WNOHANG)&.last }
      exited_at << monotonic_now
      survivors.replace(agents_alive_after(2))
    ensure
      # Each fake agent leads its own process group.
      [pid, *agent_pids].each { |group| kill_group(group) }
      Process.wait(pid) if status.nil?
    end
    status
  end

  def agent_pids = Dir.children(started_dir).map(&:to_i)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # The fake agents still alive after up to `timeout` seconds (killed agents
  # are reaped by init once agent-council has exited).
  def agents_alive_after(timeout)
    wait_until(timeout, 'agents to exit') { agent_pids.none? { |pid| alive?(pid) } }
    []
  rescue RuntimeError
    agent_pids.select { |pid| alive?(pid) }
  end

  def kill_group(pgid)
    Process.kill('KILL', -pgid)
  rescue Errno::ESRCH
    nil
  end

  # The child's output is UTF-8 whatever the locale (see the LANG=C spec).
  def out = File.read(out_path, encoding: 'UTF-8')
  def err = File.read(err_path, encoding: 'UTF-8')
  def output_report = "stdout:\n#{out}\nstderr:\n#{err}"
  def reports(pattern) = Dir.glob(File.join(work_dir, 'reports', '*', '*', pattern))

  # "Interrupted." with no stack trace; tolerates unrelated warnings (e.g.
  # from RUBYOPT=-w) in the child's stderr.
  def expect_quiet_interrupt
    expect(err).to include('Interrupted.'), output_report
    expect(err).not_to match(/:\d+:in /), output_report # a backtrace line
  end

  # Each agent got SIGTERM from agent-council, none got the terminal's
  # SIGINT, and none outlived agent-council.
  def expect_agents_terminated(count)
    expect(Dir.children(termed_dir).size).to eq(count)
    expect(Dir.children(sigint_dir)).to be_empty
    expect(survivors).to be_empty
  end

  # agent-council died by the signal, as a shell expects (so, e.g., a loop
  # running it stops on Ctrl-C), except QUIT, which exits 131 instead of
  # dumping core.
  def expect_died_by(status, signal)
    if signal == 'QUIT'
      expect(status.exitstatus).to eq(131), output_report
    else
      expect(status.termsig).to eq(Signal.list.fetch(signal)), output_report
    end
  end

  def leftover_scratch_dirs = Dir.children(child_tmp).grep(/\Aagent-council-/)

  it 'reports progress and consolidates on an uninterrupted run' do
    write_config(%w[done done], consolidator: 'done')

    status = run_council

    expect(status.exitstatus).to eq(0), output_report
    expect(out.scan(/^  ✓ \d\d:\d\d:\d\d  #[12] done/).size).to eq(4), output_report # progress and summary
    expect(out).to include('2/2 succeeded')
    expect(reports('answers/*.md').size).to eq(2)
    expect(reports('*consolidated*.md').size).to eq(1)
    expect(leftover_scratch_dirs).to be_empty
  end

  # Under a non-UTC zone, so the stamp carries a nonzero offset.
  it 'writes report timestamps that parse as Time' do
    write_config(%w[done], consolidator: 'done')

    status = run_council(env: { 'TZ' => 'Asia/Bangkok' })

    expect(status.exitstatus).to eq(0), output_report
    [*reports('answers/*.md'), *reports('*consolidated*.md')].each do |path|
      fields, = AgentCouncil.parse_front_matter(File.read(path, encoding: 'UTF-8'))
      expect(fields['timestamp']).to be_a(Time), path
      expect(fields['timestamp'].utc_offset).to eq(7 * 3600)
    end
  end

  # Under LANG=C (or LANG unset) Ruby's default external encoding is
  # US-ASCII, but reports and pi's output are UTF-8.
  it 'consolidates non-ASCII reports under a non-UTF-8 locale' do
    write_config(%w[utf8 escaped], consolidator: 'utf8')

    status = run_council(env: { 'LANG' => 'C', 'LC_ALL' => nil, 'LC_CTYPE' => nil })

    expect(status.exitstatus).to eq(0), output_report
    expect(err).not_to match(/:\d+:in /), output_report # a backtrace line
    expect(out).to match(/^  ✓ \d\d:\d\d:\d\d  utf8 \/ c \(consolidator\)/), output_report
    expect(out).to include('Summary', '2/2 succeeded')
    consolidated = reports('*consolidated*.md')
    expect(consolidated.size).to eq(1)
    expect(File.read(consolidated.first, encoding: 'UTF-8')).to include(non_ascii_answer)
  end

  it 'stops quietly on Ctrl-C, keeping finished reports and removing scratch dirs' do
    write_config(%w[done dies dies dies])

    interrupted_at = nil
    status = run_council(started: 3) do |pid|
      wait_until(5, 'the finished report') { reports('answers/*.md').size == 1 }
      interrupted_at = monotonic_now
      Process.kill('INT', -pid)
    end

    expect_died_by(status, 'INT')
    expect(monotonic_now - interrupted_at).to be < grace # didn't wait out the grace period
    expect_quiet_interrupt
    expect(out).not_to include('✗')
    expect(reports('answers/*.md').size).to eq(1)
    expect(leftover_scratch_dirs).to be_empty
    expect_agents_terminated(3)
  end

  it 'stops quietly on Ctrl-C during consolidation' do
    write_config(%w[done], consolidator: 'dies')

    interrupted_at = nil
    status = run_council(started: 1) do |pid|
      interrupted_at = monotonic_now
      Process.kill('INT', -pid)
    end

    expect_died_by(status, 'INT')
    expect(monotonic_now - interrupted_at).to be < grace
    expect_quiet_interrupt
    expect(out).to end_with("Consolidating reports:\n")
    expect(reports('answers/*.md').size).to eq(1)
    expect(leftover_scratch_dirs).to be_empty
    expect_agents_terminated(1)
  end

  %w[TERM HUP QUIT].each do |signal|
    it "treats SIG#{signal} sent to agent-council alone like Ctrl-C" do
      write_config(%w[dies dies])

      status = run_council(started: 2) { |pid| Process.kill(signal, pid) }

      expect_died_by(status, signal)
      expect_quiet_interrupt
      expect(leftover_scratch_dirs).to be_empty
      expect_agents_terminated(2)
    end
  end

  # A closing terminal can deliver two SIGHUPs at once (one forwarded by the
  # shell, one from the kernel). Sent back to back here they'd merge into
  # one pending signal, so the second follows once the first is handled.
  it 'does not let a repeated SIGHUP skip the graceful stop' do
    write_config(%w[dies dies])

    status = run_council(started: 2) do |pid|
      Process.kill('HUP', pid)
      wait_until(5, 'the first SIGHUP to be handled') { err.include?('Interrupted.') }
      Process.kill('HUP', pid)
    end

    expect_died_by(status, 'HUP')
    expect_quiet_interrupt
    expect(leftover_scratch_dirs).to be_empty
    expect_agents_terminated(2)
  end

  it 'keeps running on SIGHUP when started ignoring it, as under nohup' do
    write_config(%w[dies])

    status = run_council(started: 1, ignoring_hup: true) do |pid|
      Process.kill('HUP', pid)
      sleep 0.5
      expect(Process.wait2(pid, Process::WNOHANG)).to be_nil, output_report
      Process.kill('INT', pid)
    end

    expect_died_by(status, 'INT')
    expect_agents_terminated(1)
  end

  it 'kills agents and exits at once on a second Ctrl-C while agents survive SIGTERM' do
    write_config(%w[deaf deaf])

    second_at = nil
    status = run_council(started: 2) do |pid|
      Process.kill('INT', -pid)
      wait_until(5, 'the agents to get SIGTERM') { Dir.children(termed_dir).size == 2 }
      second_at = monotonic_now
      Process.kill('INT', -pid)
    end

    expect_died_by(status, 'INT')
    expect(exited_at.first - second_at).to be < 2 # not waiting out the grace period
    expect_quiet_interrupt
    expect_agents_terminated(2)
  end
end
