# frozen_string_literal: true

# End-to-end runs of exe/agent-council against a fake `pi`, mostly for Ctrl-C:
# SIGINT goes to agent-council's whole process group, as a terminal sends it.
# Agents run in process groups of their own, so they should get only the
# SIGTERM agent-council sends them; a fake pi that gets SIGINT records it.
# The fake pi's behavior is chosen by provider name:
# - done: answers at once with a report.
# - utf8: answers at once with a report containing non-ASCII text.
# - escaped: the same, but \u-escaped, so pi's output itself is ASCII.
# - fails: exits 1 at once.
# - capture: like done, but first saves its prompt (stdin) to captured.txt.
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
  let(:captured_path) { File.join(tmp_root, 'captured.txt') }
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
      case " $* " in
        *" --provider capture "*) cat >"#{captured_path}"; echo '#{JSON.generate(report_event('Answer.'))}'; exit 0 ;;
      esac
      cat >/dev/null
      trap 'touch "#{sigint_dir}/$$"' INT
      case " $* " in
        *" --provider done "*) echo '#{JSON.generate(report_event('Answer.'))}'; exit 0 ;;
        *" --provider utf8 "*) echo '#{JSON.generate(report_event(non_ascii_answer))}'; exit 0 ;;
        *" --provider escaped "*) echo '#{JSON.generate(report_event(non_ascii_answer), ascii_only: true)}'; exit 0 ;;
        *" --provider fails "*) echo 'boom' >&2; exit 1 ;;
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
  # extra child environment (a nil value unsets the variable). args:
  # agent-council's arguments.
  def run_council(started: 0, ignoring_hup: false, env: {}, args: %w[prompt.md config.yml])
    env = { 'PATH' => "#{bin_dir}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}", 'TMPDIR' => child_tmp, **env }
    exe = File.join(project_root, 'exe', 'agent-council')
    cmd = [RbConfig.ruby, '-I', File.join(project_root, 'lib'), exe, *args]
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
    expect(out.scan(/^  ✓ \d\d:\d\d:\d\d  #[12] done/).size).to eq(2), output_report # progress
    expect(out.scan(/^  ✓   \d\d:\d\d:\d\d  #[12] done/).size).to eq(2), output_report # reviews table
    expect(out).to include('--- Reviews complete (2/2 succeeded) ---', '--- Consolidation complete ---')
    expect(out.index('Reviews (in ')).to be < out.index('Consolidation Report (in ')
    expect(out).to match(%r{^Config:  config\.yml\nPrompt:  prompt\.md\nRun Dir: reports/\S+$}), output_report
    expect(out).to include("Review Agents (2):\n  #1 pi / done / m1\n  #2 pi / done / m2\n")
    expect(out).to include("Consolidator Agent:\n  pi / done / c\n")
    expect(reports('reviews/*.md').size).to eq(2)
    expect(reports('*consolidated*.md').size).to eq(1)
    expect(leftover_scratch_dirs).to be_empty
  end

  it 'shows a default config as [default] and its absolute path, with nothing on stderr' do
    write_config(%w[done])
    FileUtils.mv(File.join(work_dir, 'config.yml'), File.join(work_dir, 'agent-council.yml'))

    expect(run_council(args: %w[prompt.md]).exitstatus).to eq(0), output_report
    expect(out).to include("Config:  [default] #{File.join(File.realpath(work_dir), 'agent-council.yml')}\n")
    expect(err).to be_empty
  end

  it 'reports a failed consolidation without affecting the exit status' do
    write_config(%w[done], consolidator: 'fails')

    expect(run_council.exitstatus).to eq(0), output_report
    expect(out)
      .to match(/^  ✗   \d\d:\d\d:\d\d  fails \/ c \(consolidator\)  \(pi exited 1: boom\)$/), output_report
    expect(out).to end_with("\n--- Consolidation error ---\n")
    expect(reports('*consolidated*.md')).to be_empty
  end

  it 'names the prompt and config copies and records durations in analyst front matter' do
    write_config(%w[done])

    expect(run_council.exitstatus).to eq(0), output_report
    text = File.read(reports('reviews/*.md').first, encoding: 'UTF-8')
    fields, = AgentCouncil.parse_front_matter(text)
    expect(fields).to include('prompt_file' => 'prompt.md', 'config_file' => 'config.yml')
    expect(fields['run_stamp']).to match(/\A\d{4}-\d\d-\d\d-\d\d-\d\d-\d\d\z/)
    expect(fields['duration']).to match(/\A\d\d:\d\d:\d\d\z/)
    expect(text).to include("| duration | #{fields['duration']} |") # in the byline too
  end

  it 'lists only the reports consolidated, not failed agents, in source_durations' do
    write_config(%w[done fails], consolidator: 'done')

    expect(run_council.exitstatus).to eq(1), output_report
    expect(out).to include('--- Reviews complete (1/2 succeeded) ---', '--- Consolidation complete ---')
    expect(out).to match(/^  ✗   \d\d:\d\d:\d\d  #2 fails \/ m2  \(pi exited 1: boom\)$/), output_report
    consolidated = File.read(reports('*consolidated*.md').first, encoding: 'UTF-8')
    fields, = AgentCouncil.parse_front_matter(consolidated)
    expect(fields['sources']).to eq(['#1 done / m1'])
    expect(fields['source_durations'].keys).to eq(['#1 done / m1'])
  end

  describe '--consolidate' do
    # A finished run without consolidation, then its config copy given the
    # consolidator `provider`. Returns the run dir, relative to work_dir.
    def finished_run(consolidator, analysts: %w[done done])
      write_config(analysts)
      expect(run_council.exitstatus).to eq(analysts.include?('fails') ? 1 : 0), output_report
      run_dir = Dir.glob('reports/*/*', base: work_dir).first
      config = YAML.load_file(File.join(work_dir, run_dir, 'config.yml'))
      config['consolidator'] = { 'provider' => consolidator, 'model' => 'c' }
      File.write(File.join(work_dir, run_dir, 'config.yml'), YAML.dump(config))
      run_dir
    end

    def reviews_snapshot = reports('reviews/*.md').to_h { |path| [path, File.read(path)] }

    it 'consolidates an existing run in place, running no analysts' do
      run_dir = finished_run('done')
      reviews = reviews_snapshot

      status = run_council(args: ['--consolidate', run_dir])

      expect(status.exitstatus).to eq(0), output_report
      expect(out).to match(/^  ✓   \d\d:\d\d:\d\d  done \/ c \(consolidator\)  \S/), output_report
      expect(out).to include('--- Consolidation complete ---')
      expect(out).to include(
        "Config:  #{run_dir}/config.yml\nPrompt:  #{run_dir}/prompt.md\nRun Dir: #{run_dir}\n",
        "Consolidator Agent:\n  pi / done / c\n",
        "Consolidation Report (in #{run_dir}, from 2 reviews):\n"
      )
      expect(Dir.glob('reports/*/*', base: work_dir)).to eq([run_dir])
      expect(reviews_snapshot).to eq(reviews)
      consolidated = reports('*consolidated*.md')
      expect(consolidated.map { |path| File.basename(path) })
        .to eq(["#{run_dir.delete_prefix('reports/').tr('/', '-')}_prompt_consolidated_pi_done_c.md"])
      text = File.read(consolidated.first, encoding: 'UTF-8')
      expect(text).to include("### Prompt: #{File.join(run_dir, 'prompt.md')}")
      fields, = AgentCouncil.parse_front_matter(text)
      analyst, = AgentCouncil.parse_front_matter(File.read(reports('reviews/*.md').first, encoding: 'UTF-8'))
      expect(fields['timestamp']).to eq(analyst['timestamp']) # the run's
      expect(fields['consolidated_at']).to be >= fields['timestamp']
      expect(text).to match(/^\| source \| #1 done \/ m1 \(\d\d:\d\d:\d\d\) \|$/)
      expect(leftover_scratch_dirs).to be_empty
    end

    it 'consolidates a run dir that has been moved' do
      run_dir = finished_run('done')
      moved = File.join(tmp_root, 'moved-run')
      FileUtils.mv(File.join(work_dir, run_dir), moved)

      status = run_council(args: ['--consolidate', moved])

      expect(status.exitstatus).to eq(0), output_report
      expect(Dir.children(moved).grep(/_consolidated_pi_done_c\.md\z/).size).to eq(1)
    end

    it 'tells the consolidator which configured agents have no report' do
      run_dir = finished_run('capture', analysts: %w[done fails])

      expect(run_council(args: ['--consolidate', run_dir]).exitstatus).to eq(0), output_report
      expect(out).to include("Consolidation Report (in #{run_dir}, from 1 review):\n")
      expect(File.read(captured_path, encoding: 'UTF-8')).to end_with(
        "# Agents without a report\n\n- #2 fails / m2: #{AgentCouncil::MISSING_REPORT_REASON}\n"
      )
    end

    it 'exits 1, writing nothing, when the consolidation fails' do
      run_dir = finished_run('fails')

      status = run_council(args: ['--consolidate', run_dir])

      expect(status.exitstatus).to eq(1), output_report
      expect(out).to match(/✗ .*fails \/ c \(consolidator\)/), output_report
      expect(out).to include('--- Consolidation error ---')
      expect(reports('*consolidated*.md')).to be_empty
    end

    it 'stops quietly on Ctrl-C, writing nothing' do
      run_dir = finished_run('dies')

      status = run_council(started: 1, args: ['--consolidate', run_dir]) { |pid| Process.kill('INT', -pid) }

      expect_died_by(status, 'INT')
      expect_quiet_interrupt
      expect(reports('*consolidated*.md')).to be_empty
      expect(leftover_scratch_dirs).to be_empty
      expect_agents_terminated(1)
    end
  end

  it 'tells the consolidator which agents failed, and why' do
    write_config(%w[done fails], consolidator: 'capture')

    expect(run_council.exitstatus).to eq(1), output_report
    captured = File.read(captured_path, encoding: 'UTF-8')
    expect(captured).to include('## Report from #1 done / m1')
    expect(captured).to end_with("# Agents without a report\n\n- #2 fails / m2: pi exited 1: boom\n")
  end

  # Pre-claims every run dir name for the next several seconds, so the run
  # must take a suffixed one, whatever second it starts in.
  it 'suffixes a taken run dir name, in report filenames too' do
    write_config(%w[done], consolidator: 'done')
    now = Time.now
    taken = (0..10).map { |s| (now + s).strftime('%Y-%m-%d/%H-%M-%S') }
    taken.each { |name| FileUtils.mkdir_p(File.join(work_dir, 'reports', name)) }

    status = run_council

    expect(status.exitstatus).to eq(0), output_report
    run_dirs = Dir.glob('*/*', base: File.join(work_dir, 'reports')) - taken
    expect(run_dirs.size).to eq(1), run_dirs.inspect
    run_dir = run_dirs.first
    expect(taken.map { |name| "#{name}-2" }).to include(run_dir)
    expect(out).to include("Run Dir: #{File.join('reports', run_dir)}")
    expect(out.index('Run Dir:')).to be < out.index('Review Progress:') # printed at startup
    day, run_name = run_dir.split('/')
    [*reports('reviews/*.md'), *reports('*consolidated*.md')].each do |path|
      expect(path).to start_with(File.join(work_dir, 'reports', run_dir, ''))
      expect(File.basename(path)).to start_with("#{day}-#{run_name}_prompt_")
    end
    expect(File.symlink?(File.join(work_dir, 'reports', 'latest'))).to be(false)
  end

  # Under a non-UTC zone, so the stamp carries a nonzero offset.
  it 'writes report timestamps that parse as Time' do
    write_config(%w[done], consolidator: 'done')

    status = run_council(env: { 'TZ' => 'Asia/Bangkok' })

    expect(status.exitstatus).to eq(0), output_report
    [*reports('reviews/*.md'), *reports('*consolidated*.md')].each do |path|
      fields, = AgentCouncil.parse_front_matter(File.read(path, encoding: 'UTF-8'))
      expect(fields['timestamp']).to be_a(Time), path
      expect(fields['timestamp'].utc_offset).to eq(7 * 3600)
    end
    consolidated_text = File.read(reports('*consolidated*.md').first, encoding: 'UTF-8')
    consolidated, = AgentCouncil.parse_front_matter(consolidated_text)
    expect(consolidated['consolidated_at']).to be_a(Time)
    expect(consolidated['consolidated_at'].utc_offset).to eq(7 * 3600)
  end

  # Under LANG=C (or LANG unset) Ruby's default external encoding is
  # US-ASCII, but reports and pi's output are UTF-8.
  it 'consolidates non-ASCII reports under a non-UTF-8 locale' do
    write_config(%w[utf8 escaped], consolidator: 'utf8')

    status = run_council(env: { 'LANG' => 'C', 'LC_ALL' => nil, 'LC_CTYPE' => nil })

    expect(status.exitstatus).to eq(0), output_report
    expect(err).not_to match(/:\d+:in /), output_report # a backtrace line
    expect(out).to match(/^  ✓   \d\d:\d\d:\d\d  utf8 \/ c \(consolidator\)/), output_report
    expect(out).to include('Reviews (in ', '2/2 succeeded')
    consolidated = reports('*consolidated*.md')
    expect(consolidated.size).to eq(1)
    expect(File.read(consolidated.first, encoding: 'UTF-8')).to include(non_ascii_answer)
  end

  it 'stops quietly on Ctrl-C, keeping finished reports and removing scratch dirs' do
    write_config(%w[done dies dies dies])

    interrupted_at = nil
    status = run_council(started: 3) do |pid|
      wait_until(5, 'the finished report') { reports('reviews/*.md').size == 1 }
      interrupted_at = monotonic_now
      Process.kill('INT', -pid)
    end

    expect_died_by(status, 'INT')
    expect(monotonic_now - interrupted_at).to be < grace # didn't wait out the grace period
    expect_quiet_interrupt
    expect(out).not_to include('✗')
    expect(reports('reviews/*.md').size).to eq(1)
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
    expect(out).to match(%r{\nConsolidation Report \(in reports/[^)]+\):\n\z}), output_report
    expect(reports('reviews/*.md').size).to eq(1)
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
