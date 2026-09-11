# frozen_string_literal: true

# Plan 118: the runtime floor silently excluded the gem's own major
# for four releases (~> 0.6 kept resolving while kotoshu moved to
# 1.0). A shipped constraint nobody reads must be guarded by a spec
# that reads it.
RSpec.describe "kotoshu-server gemspec" do
  let(:spec) do
    Gem::Specification.load(File.expand_path("../kotoshu-server.gemspec", __dir__))
  end

  it "floors kotoshu on the engine line it actually rides" do
    dependency = spec.dependencies.find { |d| d.name == "kotoshu" }

    expect(dependency).not_to be_nil
    expect(dependency.requirement).to be_satisfied_by(Gem::Version.new(Kotoshu::VERSION))
  end
end
