# frozen_string_literal: true

RSpec.describe SecurityBox::RactorPool do
  # Integration suite against the real ruby.wasm, executed inside Ractor
  # workers. Each eval boots a guest (~240ms); pool creation deserializes the
  # compiled module from the disk cache (~0.5s).
  around do |example|
    Timeout.timeout(120) { example.run }
  end

  describe "#eval" do
    it "runs code on a Ractor worker and returns the value" do
      pool = described_class.new(size: 2)

      result = pool.eval("40 + 2")

      expect(result).to be_ok
      expect(result.status).to eq(:ok)
      expect(result.value).to eq(42)
      expect(result.fuel_used).to be > 0
    ensure
      pool&.shutdown
    end

    it "serves many sequential evals from the same pool" do
      pool = described_class.new(size: 1)

      values = 3.times.map { |i| pool.eval("#{i} + 1").value }

      expect(values).to eq([1, 2, 3])
      expect(pool.metrics[:evals]).to eq(3)
    ensure
      pool&.shutdown
    end

    it "runs evals concurrently across workers" do
      pool = described_class.new(size: 2)
      results = []

      threads = 2.times.map { |i| Thread.new { results[i] = pool.eval("#{i} + 1") } }
      threads.each(&:join)

      expect(results.map(&:value)).to contain_exactly(1, 2)
      expect(pool.metrics[:evals]).to eq(2)
    ensure
      pool&.shutdown
    end

    it "maps user exceptions and timeouts like Sandbox#eval" do
      pool = described_class.new(size: 1)

      error = pool.eval('raise ArgumentError, "boom"')
      expect(error.status).to eq(:error)
      expect(error.error["class"]).to eq("ArgumentError")

      timeout = pool.eval("while true; end", timeout_ms: 300)
      expect(timeout.status).to eq(:timeout)

      # The worker survives the trap and keeps serving.
      expect(pool.eval("1 + 1").value).to eq(2)
    ensure
      pool&.shutdown
    end
  end

  describe "lifecycle" do
    it "raises PoolClosed on eval after shutdown" do
      pool = described_class.new(size: 1)
      pool.shutdown

      expect { pool.eval("1") }.to raise_error(SecurityBox::PoolClosed)
    end
  end
end
