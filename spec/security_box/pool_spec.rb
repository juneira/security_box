# frozen_string_literal: true

RSpec.describe SecurityBox::Pool do
  # Integration suite against the real ruby.wasm: each eval boots a guest.
  around do |example|
    Timeout.timeout(60) { example.run }
  end

  describe "#eval" do
    it "runs code on a pooled sandbox" do
      pool = described_class.new(size: 2)

      result = pool.eval("40 + 2")

      expect(result).to be_ok
      expect(result.value).to eq(42)
      expect(pool.metrics[:evals]).to eq(1)
      expect(pool.metrics[:avg_ms]).to be > 0
    ensure
      pool&.shutdown
    end

    it "accepts a named profile and per-call overrides" do
      SecurityBox.register(:pool_spec_lean) { |c| c.fuel 20_000_000_000 }
      pool = described_class.new(:pool_spec_lean, size: 1)

      expect(pool.eval("1 + 1")).to be_ok
      expect(pool.eval("while true; end", timeout_ms: 300).status).to eq(:timeout)
    ensure
      pool&.shutdown
      SecurityBox::Registry.clear!
    end
  end

  describe "bounding" do
    it "serves concurrent evals from at most `size` sandbox objects" do
      pool = described_class.new(size: 2)
      results = []

      threads = 4.times.map { |i| Thread.new { results[i] = pool.eval("#{i} + 1") } }
      threads.each(&:join)

      expect(results.map(&:value)).to contain_exactly(1, 2, 3, 4)
      expect(pool.metrics[:evals]).to eq(4)
      expect(pool.metrics[:created]).to eq(2) # bounded, reused
    ensure
      pool&.shutdown
    end

    it "raises PoolClosed on eval after shutdown" do
      pool = described_class.new(size: 1)
      pool.shutdown

      expect { pool.eval("1") }.to raise_error(SecurityBox::PoolClosed)
    end
  end
end
