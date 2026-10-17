# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AgentCouncil do
  describe '.windows?' do
    def stub_host_os(host_os)
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => host_os))
    end

    # mswin32 is also what JRuby reports on Windows.
    %w[mingw32 mswin64 mswin32].each do |host_os|
      it "is true for host_os #{host_os}" do
        stub_host_os(host_os)
        expect(described_class.windows?).to be(true)
      end
    end

    %w[linux linux-gnu darwin23].each do |host_os|
      it "is false for host_os #{host_os}" do
        stub_host_os(host_os)
        expect(described_class.windows?).to be(false)
      end
    end
  end
end
