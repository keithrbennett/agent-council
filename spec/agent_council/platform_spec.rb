# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AgentCouncil do
  describe '.windows?' do
    %w[x64-mingw-ucrt x64-mingw32 i386-mswin32].each do |platform|
      it "is true for #{platform}" do
        stub_const('RUBY_PLATFORM', platform)
        expect(described_class.windows?).to be(true)
      end
    end

    %w[x86_64-linux aarch64-linux arm64-darwin23].each do |platform|
      it "is false for #{platform}" do
        stub_const('RUBY_PLATFORM', platform)
        expect(described_class.windows?).to be(false)
      end
    end
  end
end
