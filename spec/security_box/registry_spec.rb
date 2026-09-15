# frozen_string_literal: true

RSpec.describe SecurityBox::Registry do
  before { described_class.clear! }

  describe ".register" do
    it "stores a configuration resolvable by name" do
      described_class.register(:lean) { |c| c.fuel 5_000_000 }

      config = described_class.resolve(:lean)
      expect(config).to be_a(SecurityBox::Configuration)
      expect(config).to be_frozen
      expect(config.fuel).to eq(5_000_000)
      expect(config.timeout_ms).to eq(SecurityBox::Configuration.build.timeout_ms)
    end

    it "accepts String names and normalizes them to Symbols" do
      described_class.register("lean") { |c| c.fuel 1 }

      expect(described_class.resolve(:lean)).to eq(described_class.resolve("lean"))
    end

    it "works without a block (defaults only)" do
      described_class.register(:default)

      expect(described_class.resolve(:default).to_h)
        .to eq(SecurityBox::Configuration.build.to_h)
    end

    it "rejects duplicate names" do
      described_class.register(:lean)

      expect { described_class.register(:lean) }
        .to raise_error(SecurityBox::InvalidConfiguration, /already registered/)
    end

    it "rejects non-Symbol names" do
      expect { described_class.register(42) }
        .to raise_error(SecurityBox::InvalidConfiguration, /must be a Symbol or String/)
    end

    it "does not mutate the base profile when deriving" do
      described_class.register(:base) { |c| c.fuel 100 }
      described_class.register(:derived, from: :base) { |c| c.fuel 200 }

      expect(described_class.resolve(:base).fuel).to eq(100)
      expect(described_class.resolve(:derived).fuel).to eq(200)
    end

    it "rejects an unknown base profile" do
      expect { described_class.register(:lean, from: :missing) }
        .to raise_error(SecurityBox::InvalidConfiguration, /unknown base profile/)
    end
  end

  describe ".resolve" do
    it "raises for unknown profiles" do
      expect { described_class.resolve(:missing) }
        .to raise_error(SecurityBox::InvalidConfiguration, /unknown profile/)
    end

    it "rejects non-Symbol lookups" do
      expect { described_class.resolve(nil) }
        .to raise_error(SecurityBox::InvalidConfiguration, /must be a Symbol or String/)
    end
  end

  describe ".profiles" do
    it "lists the registered names" do
      described_class.register(:a)
      described_class.register(:b)

      expect(described_class.profiles.keys).to contain_exactly(:a, :b)
    end
  end
end

RSpec.describe SecurityBox do
  before { SecurityBox::Registry.clear! }

  describe ".register" do
    it "is the public entry point for Registry.register" do
      SecurityBox.register(:lean) { |c| c.fuel 1_000 }

      expect(SecurityBox::Registry.resolve(:lean).fuel).to eq(1_000)
    end
  end

  describe ".spawn" do
    it "builds a Sandbox from a registered profile" do
      SecurityBox.register(:lean) { |c| c.fuel 1_000 }

      sandbox = SecurityBox.spawn(:lean)
      expect(sandbox).to be_a(SecurityBox::Sandbox)
      expect(sandbox.instance_variable_get(:@config).fuel).to eq(1_000)
    end

    it "derives per-call overrides without mutating the profile" do
      SecurityBox.register(:lean) { |c| c.fuel 1_000 }

      sandbox = SecurityBox.spawn(:lean, fuel: 2_000)
      expect(sandbox.instance_variable_get(:@config).fuel).to eq(2_000)
      expect(SecurityBox::Registry.resolve(:lean).fuel).to eq(1_000)
    end

    it "accepts a Configuration instance" do
      config = SecurityBox::Configuration.build(fuel: 3_000)

      sandbox = SecurityBox.spawn(config)
      expect(sandbox.instance_variable_get(:@config)).to eq(config)
    end

    it "accepts a Configuration instance with overrides" do
      config = SecurityBox::Configuration.build(fuel: 3_000)

      sandbox = SecurityBox.spawn(config, timeout_ms: 777)
      expect(sandbox.instance_variable_get(:@config).timeout_ms).to eq(777)
      expect(sandbox.instance_variable_get(:@config).fuel).to eq(3_000)
    end

    it "builds from the defaults when no profile is given" do
      sandbox = SecurityBox.spawn

      expect(sandbox.instance_variable_get(:@config).to_h)
        .to eq(SecurityBox::Configuration.build.to_h)
    end

    it "rejects unsupported profile types" do
      expect { SecurityBox.spawn(42) }.to raise_error(ArgumentError, /registered name or a Configuration/)
    end
  end
end
