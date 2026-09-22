# frozen_string_literal: true

require "spec_helper"

require "security_box/configuration"
require "security_box/errors"

RSpec.describe SecurityBox::Rpcs do
  let(:handler) { ->(args) { args } }

  describe ".normalize" do
    it "accepts a hash of name => callable" do
      rpcs = described_class.normalize({ "echo" => handler })

      expect(rpcs).to eq({ "echo" => handler })
      expect(rpcs).to be_frozen
    end

    it "accepts an array of one-pair hashes (register DSL form)" do
      rpcs = described_class.normalize([{ "a" => handler }, { "b" => handler }])

      expect(rpcs.keys).to eq(%w[a b])
    end

    it "normalizes nil to an empty frozen hash" do
      expect(described_class.normalize(nil)).to eq({})
      expect(described_class.normalize(nil)).to be_frozen
    end

    it "rejects non-hash, non-array values" do
      expect { described_class.normalize("echo" => handler) }.not_to raise_error
      expect { described_class.normalize(42) }
        .to raise_error(SecurityBox::InvalidConfiguration, /must be a Hash/)
    end

    it "rejects array entries that are not one-pair hashes" do
      expect { described_class.normalize(["echo"]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /one-pair hashes/)
      expect { described_class.normalize([{ "a" => handler, "b" => handler }]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /one-pair hashes/)
    end

    it "rejects non-string and empty names" do
      expect { described_class.normalize(:echo => handler) }
        .to raise_error(SecurityBox::InvalidConfiguration, /non-empty String/)
      expect { described_class.normalize("" => handler) }
        .to raise_error(SecurityBox::InvalidConfiguration, /non-empty String/)
    end

    it "rejects handlers that do not respond to #call" do
      expect { described_class.normalize("echo" => "nope") }
        .to raise_error(SecurityBox::InvalidConfiguration, /respond to #call/)
    end

    it "rejects duplicate names" do
      expect { described_class.normalize([{ "echo" => handler }, { "echo" => handler }]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /duplicate/)
    end

    it "rejects more than the maximum number of handlers" do
      many = (0...SecurityBox::Rpcs::MAX_RPCS + 1).map { |i| { "rpc#{i}" => handler } }

      expect { described_class.normalize(many) }
        .to raise_error(SecurityBox::InvalidConfiguration, /too many rpcs/)
    end
  end
end

RSpec.describe SecurityBox::Registry do
  let(:handler) { ->(args) { args } }

  before { described_class.clear! }

  it "collects c.rpc calls in the register DSL, one pair at a time" do
    described_class.register(:rpc) do |c|
      c.rpc "a" => handler
      c.rpc "b" => handler
    end

    expect(described_class.resolve(:rpc).rpcs.keys).to eq(%w[a b])
  end

  it "rejects a malformed c.rpc mapping" do
    expect { described_class.register(:bad) { |c| c.rpc("a", echo: handler) } }
      .to raise_error(SecurityBox::InvalidConfiguration, /exactly one pair/)
    expect { described_class.register(:bad2) { |c| c.rpc({ "a" => handler, "b" => handler }) } }
      .to raise_error(SecurityBox::InvalidConfiguration, /exactly one pair/)
  end

  it "accepts symbol keys (converted to strings)" do
    described_class.register(:sym) { |c| c.rpc echo: handler }

    expect(described_class.resolve(:sym).rpcs).to eq({ "echo" => handler })
  end

  it "validates rpcs passed to the DSL" do
    expect { described_class.register(:bad) { |c| c.rpc "echo" => "nope" } }
      .to raise_error(SecurityBox::InvalidConfiguration, /respond to #call/)
  end
end

RSpec.describe SecurityBox::Configuration do
  let(:handler) { ->(args) { args } }

  it "stores normalized rpcs" do
    config = described_class.build(rpcs: { "echo" => handler })

    expect(config.rpcs).to eq({ "echo" => handler })
  end

  it "excludes rpcs from the fingerprint" do
    base = described_class.build(rpcs: { "echo" => handler })
    other = described_class.build(rpcs: { "echo" => ->(args) { args.inspect } })

    expect(base.fingerprint).to eq(other.fingerprint)
    expect(base.fingerprint).to eq(described_class.build.fingerprint)
  end

  it "replaces (not merges) rpcs on #with, like env:" do
    config = described_class.build(rpcs: { "echo" => handler })

    expect(config.with(rpcs: { "other" => handler }).rpcs).to eq({ "other" => handler })
    expect(config.with(rpcs: {}).rpcs).to eq({})
    expect(config.rpcs).to eq({ "echo" => handler }) # original untouched
  end
end

RSpec.describe SecurityBox::RactorPool do
  let(:handler) { ->(args) { args } }

  it "rejects configurations carrying rpcs (handlers cannot cross a Ractor boundary)" do
    config = SecurityBox::Configuration.build(rpcs: { "echo" => handler })

    expect { described_class.new(config, size: 1) }
      .to raise_error(SecurityBox::InvalidConfiguration, /not supported on RactorPool/)
  end
end
