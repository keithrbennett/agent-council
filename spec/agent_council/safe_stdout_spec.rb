# frozen_string_literal: true

# Focused tests for lib/agent_council/safe_stdout.rb. Run with: rspec
require 'spec_helper'
require 'stringio'
require 'open3'

RSpec.describe AgentCouncil::SafeStdout do
  let(:io) { StringIO.new }
  let(:stdout) { described_class.new(io) }

  it 'passes puts, print, printf, <<, and write through, as IO does' do
    stdout.puts('a', %w[b c])
    stdout.print('d', [1, 2])
    stdout.printf("%03d\n", 7)
    stdout << 'f' << "\n"
    expect(stdout.write("g\n")).to eq(2)
    expect(stdout.flush).to equal(stdout)
    expect(io.string).to eq("a\nb\nc\nd[1, 2]007\nf\ng\n")
  end

  # As with LANG=ISO-8859-1, in a child Ruby: the progress marks are UTF-8.
  it 'writes UTF-8 text whatever the default external encoding' do
    lib = File.expand_path('../../lib', __dir__)
    script = '$stdout = AgentCouncil::SafeStdout.new($stdout); puts "\\u2713 done"'
    ruby = [RbConfig.ruby, '-E', 'ISO-8859-1', '-I', lib, '-ragent_council']
    out, err, status = Open3.capture3(*ruby, '-e', script, binmode: true)
    expect(status).to be_success, err
    expect(out).to eq("\u2713 done\n".b)
  end

  def broken(*failing)
    instance_double(IO).tap do |double|
      failing.each { |name| allow(double).to receive(name).and_raise(Errno::EPIPE) }
    end
  end

  # Otherwise agent-council would die, losing run.json and leaving its
  # agents running.
  it 'discards output from then on once a write fails, as JRuby fails' do
    stdout = described_class.new(broken(:write, :puts))
    expect { stdout.puts('lost') }.not_to raise_error
    expect { stdout.puts('also lost') || stdout.flush }.not_to raise_error
  end

  it 'discards output from then on once a flush fails, as MRI fails' do
    stdout = described_class.new(broken(:flush))
    expect { stdout.flush }.not_to raise_error
    expect { stdout.puts('lost') || stdout.flush }.not_to raise_error
  end

  # In a child Ruby, whose stdout is a pipe with no reader: buffered and
  # unbuffered writes, a write larger than MRI's buffer, and a spawn (MRI
  # flushes $stdout first).
  it 'keeps a real closed pipe from raising' do
    script = <<~RUBY
      $stdout = AgentCouncil::SafeStdout.new($stdout)
      puts 'line'
      puts 'x' * 100_000
      $stdout.flush
      Process.wait(Process.spawn('true'))
      puts 'after'
      exit 0
    RUBY
    reader, writer = IO.pipe
    reader.close
    lib = File.expand_path('../../lib', __dir__)
    pid = Process.spawn(RbConfig.ruby, '-I', lib, '-ragent_council', '-e', script, out: writer, err: File::NULL)
    writer.close
    expect(Process.wait2(pid).last.exitstatus).to eq(0)
  end
end
