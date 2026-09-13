# frozen_string_literal: true

RSpec.describe SecurityBox::Configuration do
  it "has sensible defaults" do
    config = described_class.build

    expect(config.fuel).to eq(10_000_000_000)
    expect(config.timeout_ms).to eq(2_000)
    expect(config.memory_size).to eq(512 * 1024 * 1024)
    expect(config.stdout_limit).to eq(1 << 20)
    expect(config.stderr_limit).to eq(1 << 16)
    expect(config.epoch_interval_ms).to eq(25)
    expect(config.image_path).to be_a(String)
  end

  it "accepts overrides" do
    config = described_class.build(fuel: 1_000, timeout_ms: 100)

    expect(config.fuel).to eq(1_000)
    expect(config.timeout_ms).to eq(100)
  end

  it "is frozen" do
    expect(described_class.build).to be_frozen
  end

  describe "#with" do
    it "returns a modified copy without mutating the original" do
      original = described_class.build(fuel: 100)
      derived = original.with(fuel: 200)

      expect(derived.fuel).to eq(200)
      expect(original.fuel).to eq(100)
      expect(derived.timeout_ms).to eq(original.timeout_ms)
    end
  end
end
