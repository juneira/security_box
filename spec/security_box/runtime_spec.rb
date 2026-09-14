# frozen_string_literal: true

RSpec.describe SecurityBox::Runtime do
  let(:config) { SecurityBox::Configuration.build }

  around do |example|
    Timeout.timeout(120) { example.run }
  end

  describe ".module_for" do
    it "serves a fresh engine from the disk cache without recompiling" do
      # Warm the cache through a regular execution (first suite eval pays the
      # compile; later ones deserialize).
      expect(SecurityBox.eval("1 + 1")).to be_ok

      fresh_engine = Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true)
      if fresh_engine.respond_to?(:start_epoch_interval)
        fresh_engine.start_epoch_interval(config.epoch_interval_ms)
      end
      allow(SecurityBox::ModuleCache).to receive(:compile_and_store)
        .and_raise("module_for must not recompile when the cache is warm")

      expect(SecurityBox::Runtime.module_for(fresh_engine, config.image_path))
        .to be_a(Wasmtime::Module)
    end
  end
end
