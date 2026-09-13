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

  describe "default image resolution" do
    around do |example|
      previous = ENV[described_class::IMAGE_ENV_VAR]
      ENV.delete(described_class::IMAGE_ENV_VAR)
      example.run
    ensure
      if previous
        ENV[described_class::IMAGE_ENV_VAR] = previous
      else
        ENV.delete(described_class::IMAGE_ENV_VAR)
      end
    end

    before do
      allow(File).to receive(:file?).and_call_original
    end

    let(:asset_path) do
      File.expand_path(described_class::IMAGE_ASSET_RELATIVE,
                       File.expand_path("../../lib/security_box", __dir__))
    end
    let(:dev_path) do
      File.expand_path(described_class::IMAGE_DEV_RELATIVE,
                       File.expand_path("../../lib/security_box", __dir__))
    end

    it "uses the packaged asset by default" do
      allow(File).to receive(:file?).with(asset_path).and_return(true)
      allow(File).to receive(:file?).with(dev_path).and_return(false)

      expect(described_class.build.image_path).to eq(asset_path)
    end

    it "prefers SECURITY_BOX_IMAGE over the packaged asset" do
      ENV[described_class::IMAGE_ENV_VAR] = "/opt/custom.wasm"
      allow(File).to receive(:file?).with("/opt/custom.wasm").and_return(true)
      allow(File).to receive(:file?).with(asset_path).and_return(true)

      expect(described_class.build.image_path).to eq("/opt/custom.wasm")
    end

    it "falls back to the legacy build/ path when the asset is missing" do
      allow(File).to receive(:file?).with(asset_path).and_return(false)
      allow(File).to receive(:file?).with(dev_path).and_return(true)

      expect(described_class.build.image_path).to eq(dev_path)
    end

    it "raises ImageMissing listing every tried location when nothing exists" do
      allow(File).to receive(:file?).with(asset_path).and_return(false)
      allow(File).to receive(:file?).with(dev_path).and_return(false)

      expect { described_class.build }
        .to raise_error(SecurityBox::ImageMissing) { |error|
          expect(error.message).to include(described_class::IMAGE_ENV_VAR)
          expect(error.message).to include(asset_path)
          expect(error.message).to include(dev_path)
          expect(error.message).to include("rake security_box:build_image")
        }
    end
  end
end
