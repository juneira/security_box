# frozen_string_literal: true

RSpec.describe "RSpec inside the sandbox image" do
  # The image bundles rspec (lib/security_box/guest_ext/Gemfile). Older or
  # custom images may not, so the suite skips instead of failing.
  def self.rspec_available?
    return @rspec_available if defined?(@rspec_available)

    @rspec_available =
      begin
        result = SecurityBox.eval(<<~'RUBY', timeout_ms: 10_000)
          require "/bundle/setup.rb"
          require "rspec/core"
          true
        RUBY
        result.ok?
      rescue StandardError
        false
      end
  end

  before do
    skip "sandbox image does not bundle rspec" unless self.class.rspec_available?
  end

  it "runs a passing suite and returns status 0" do
    result = SecurityBox.eval(<<~'RUBY', timeout_ms: 30_000, fuel_ms: 20_000)
      Dir.mkdir("/work/spec") unless Dir.exist?("/work/spec")
      File.write("/work/calc.rb", <<~SRC)
        module Calc
          def self.add(a, b) = a + b
        end
      SRC
      File.write("/work/spec/calc_spec.rb", <<~SPEC)
        require "/work/calc"
        RSpec.describe "Calc" do
          it("adds") { expect(Calc.add(2, 3)).to eq(5) }
        end
      SPEC
      SB.run_rspec("--no-color", "/work/spec")
    RUBY

    expect(result).to be_ok
    expect(result.value).to eq(0)
    expect(result.stdout).to include("1 example, 0 failures")
  end

  it "returns status 1 and reports failures" do
    result = SecurityBox.eval(<<~'RUBY', timeout_ms: 30_000, fuel_ms: 20_000)
      Dir.mkdir("/work/spec") unless Dir.exist?("/work/spec")
      File.write("/work/calc.rb", <<~SRC)
        module Calc
          def self.add(a, b) = a + b
        end
      SRC
      File.write("/work/spec/calc_spec.rb", <<~SPEC)
        require "/work/calc"
        RSpec.describe "Calc" do
          it("fails") { expect(Calc.add(2, 2)).to eq(5) }
        end
      SPEC
      SB.run_rspec("--no-color", "/work/spec")
    RUBY

    expect(result).to be_ok
    expect(result.value).to eq(1)
    expect(result.stdout).to include("1 example, 1 failure")
    expect(result.stdout).to include("expected: 5")
  end
end
