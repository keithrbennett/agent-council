# frozen_string_literal: true

# Tests for lib/agent_council/harnesses.rb: harness lookup by name and the
# scaffolding every harness shares (no model calls). Run with: rspec
require 'spec_helper'

RSpec.describe AgentCouncil::Harnesses do
  describe '.name_of' do
    it "gives an entry's harness, or pi for one that names none" do
      expect(described_class.name_of({ 'harness' => 'other' })).to eq('other')
      expect(described_class.name_of({ 'provider' => 'p' })).to eq('pi')
      expect(described_class.name_of(nil)).to eq('pi')
    end

    it 'reads a non-string value, as in hand-edited front matter, as the default' do
      expect(described_class.name_of({ 'harness' => false })).to eq('pi')
    end
  end

  describe '.module_for' do
    it "returns the module of the entry's harness" do
      expect(described_class.module_for({ 'harness' => 'pi' })).to be(AgentCouncil::Harnesses::PiHarness)
      expect(described_class.module_for({})).to be(AgentCouncil::Harnesses::PiHarness)
    end

    it 'raises KeyError for an unknown harness' do
      expect { described_class.module_for({ 'harness' => 'nope' }) }.to raise_error(KeyError)
    end
  end

  # The invariants below hold vacuously for an empty registry.
  it 'has at least one harness' do
    expect(described_class::BY_NAME).not_to be_empty
  end

  # What AgentCouncil calls on every harness (see harnesses.rb).
  it 'gives every harness the whole interface' do
    interface = %i[argv usage error_message exit_detail warnings final_response assistant_messages]
    described_class::BY_NAME.each_value do |harness|
      expect(harness).to respond_to(*interface)
    end
  end

  it 'names each harness by its own NAME' do
    expect(described_class::BY_NAME).to all(satisfy { |name, harness| name == harness::NAME })
  end

  # The startup check looks for NAME on PATH, so it must be what argv runs.
  it 'runs each harness as its NAME' do
    runs_as_name = satisfy { |harness| harness.argv('p', 'm').first == harness::NAME }
    expect(described_class::BY_NAME.values).to all(runs_as_name)
  end

  # Harness names go into report filenames unsanitized; validation admits
  # only these names, so each must already be filename-safe.
  it 'has only names that are safe in a filename' do
    expect(described_class::BY_NAME.keys).to all(satisfy { |name| AgentCouncil.sanitize(name) == name })
  end

  describe '.scaffold_text' do
    subject(:scaffold) { described_class.scaffold_text }

    # Under Claude Code's sandbox the scratch dir itself is read-only, but
    # $TMPDIR (a dir inside it) is writable, so agents are sent there.
    it 'points agents at $TMPDIR for scratch space, not at a path' do
      expect(scaffold).to include('$TMPDIR')
      expect(scaffold).not_to include('agent-council-') # Dir.mktmpdir's prefix
    end

    # Safety-critical invariants; deliberate rewording should update these.
    it 'states the read-only rules' do
      expect(scaffold).to match(/do not modify/i)
      expect(scaffold).to match(/do not act outside this machine/i) # agents may have MCP tools that write
      expect(scaffold).to match(/test suites/i) # no stateful commands...
      expect(scaffold).to match(/unless the user's prompt explicitly permits/i) # ...unless the prompt allows
    end

    it 'requires the analysis as the final message, not a file' do
      expect(scaffold).to match(/final message/i)
    end
  end
end
