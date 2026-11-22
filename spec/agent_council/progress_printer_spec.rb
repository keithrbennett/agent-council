# frozen_string_literal: true

# Focused tests for lib/agent_council/progress_printer.rb. Run with: rspec
require 'spec_helper'
require 'stringio'

RSpec.describe AgentCouncil::ProgressPrinter do
  let(:out) { StringIO.new }
  let(:printer) { described_class.new(2, out: out) }

  it 'prints pid lines as agents start, then finish lines under one heading' do
    printer.started('#1 a / m1', 11)
    printer.started('#2 b / m2', 12)
    printer.finished('#2 b / m2', ['  ✓ 00:00:01  #2 b / m2'])
    printer.finished('#1 a / m1', ['  ✗ 00:00:02  #1 a / m1', '      boom'])
    expect(out.string).to eq(<<~OUT)
        - pid 11  #1 a / m1
        - pid 12  #2 b / m2

      Finished Agents:
        ✓ 00:00:01  #2 b / m2
        ✗ 00:00:02  #1 a / m1
            boom
    OUT
  end

  it 'holds a finish line until every agent has started' do
    printer.started('#1 a / m1', 11)
    printer.finished('#1 a / m1', ['  ✓ 00:00:01  #1 a / m1'])
    expect(out.string).not_to include('✓')
    printer.started('#2 b / m2', 12)
    expect(out.string).to end_with("  - pid 12  #2 b / m2\n\nFinished Agents:\n  ✓ 00:00:01  #1 a / m1\n")
  end

  it 'counts an agent that finished without starting, as one that failed to spawn' do
    printer.finished('#1 a / m1', ['  ✗ 00:00:00  #1 a / m1'])
    expect(out.string).to eq('')
    printer.started('#2 b / m2', 12)
    expect(out.string).to end_with("Finished Agents:\n  ✗ 00:00:00  #1 a / m1\n")
  end

  it 'prints what it holds when told to, as when collecting ended early' do
    printer.started('#1 a / m1', 11)
    printer.finished('#1 a / m1', ['  ✓ 00:00:01  #1 a / m1'])
    printer.flush_held
    expect(out.string).to end_with("Finished Agents:\n  ✓ 00:00:01  #1 a / m1\n")
  end
end
