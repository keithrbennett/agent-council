# frozen_string_literal: true

# Tests for lib/agent_council/harnesses/harness.rb: the base class's
# defaults and the methods it leaves to each harness (no model calls).
# Run with: rspec
require 'spec_helper'

RSpec.describe AgentCouncil::Harnesses::Harness do
  # A NoMethodError, not NotImplementedError (a ScriptError), so that
  # run_agent's rescue fails only the agent whose harness lacks one.
  it 'raises NoMethodError, naming the harness, for each method a harness must define' do
    harness = stub_const('SomeHarness', Class.new(described_class))
    calls = { argv: %w[p m], usage: [''], error_message: [''], final_response: [''],
              assistant_messages: [''] }
    calls.each do |name, args|
      expect { harness.public_send(name, *args) }
        .to raise_error(NoMethodError, "SomeHarness must define #{name}") { |e| expect(e.name).to eq(name) }
    end
  end

  it 'gives no variables and no warnings by default' do
    expect(described_class.env('/scratch')).to eq({})
    expect(described_class.warnings('')).to eq([])
  end

  it "explains a nonzero exit by stderr's first nonblank line by default" do
    expect(described_class.exit_detail('ignored', "\n  boom  \nmore\n")).to eq('boom')
    expect(described_class.exit_detail('', " \n")).to eq(described_class::NO_ERROR_OUTPUT)
  end

  it 'reads --provider and --model, either of which may be missing, by default' do
    expect(described_class.model_label(%w[h --provider p --model m])).to eq('p / m')
    expect(described_class.model_label(%w[h --model m])).to eq('m')
    expect(described_class.model_label(%w[h --provider])).to eq('')
    expect(described_class.model_label(%w[h])).to eq('')
  end
end
