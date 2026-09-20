# frozen_string_literal: true

module SecurityBox
  # Bounded pool of :oneshot Sandboxes.
  #
  # What it gives you:
  # - a hard cap on concurrent sandbox evaluations (`size`);
  # - cheap checkout/checkin of pre-built Sandbox objects;
  # - basic metrics (evals, total/average wall time).
  #
  # What it does NOT give you (measured in stage 4, docs/plan/stages/stage_4.md):
  # parallelism. `invoke` holds the GVL for the whole guest lifetime, so
  # concurrent evals on threads serialize. For real parallelism use
  # RactorPool, which runs workers on Ractors with a shared Engine+Module.
  #
  # Usage:
  #   pool = SecurityBox::Pool.new(:lean, size: 4)
  #   pool.eval("1 + 1")                # => Result (checks out a sandbox)
  #   pool.checkout { |sandbox| ... }   # manual checkout block
  #   pool.shutdown
  class Pool
    attr_reader :size

    def initialize(profile = nil, size: 4, **options)
      @size = Integer(size)
      raise ArgumentError, "size must be >= 1" if @size < 1

      @config = resolve_config(profile, options)
      @sandboxes = Queue.new
      @mutex = Mutex.new
      @created = 0
      @closed = false
      @metrics = { evals: 0, total_ms: 0.0 }
    end

    # Checks a sandbox out of the pool for the duration of the block.
    # Blocks while all `size` sandboxes are busy.
    def checkout
      raise PoolClosed, "pool is closed" if closed?

      sandbox = acquire
      begin
        yield sandbox
      ensure
        release(sandbox)
      end
    end

    # Checks a sandbox out and runs `code` on it. Per-call overrides are
    # forwarded to Sandbox#eval.
    def eval(code, **overrides)
      t0 = monotonic_ms
      result = checkout { |sandbox| sandbox.eval(code, **overrides) }
      record(monotonic_ms - t0)
      result
    end

    # Snapshot of the counters:
    # {size:, created:, evals:, total_ms:, avg_ms:}.
    def metrics
      @mutex.synchronize do
        evals = @metrics[:evals]
        { size: @size, created: @created, evals: evals,
          total_ms: @metrics[:total_ms].round(2),
          avg_ms: evals.zero? ? 0.0 : (@metrics[:total_ms] / evals).round(2) }
      end
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    # Closes the pool. Sandboxes currently checked out keep working until
    # released; threads blocked on an empty pool keep waiting (callers must
    # ensure they do not shut down while checkouts are still being awaited).
    def shutdown
      @mutex.synchronize { @closed = true }
    end

    private

    def resolve_config(profile, options)
      case profile
      when nil then Configuration.build(**options)
      when Symbol, String then Registry.resolve(profile).with(**options)
      when Configuration then profile.with(**options)
      else raise ArgumentError, "profile must be a registered name or a Configuration, got #{profile.class}"
      end
    end

    # Hands out an existing sandbox, creates a new one while under `size`, or
    # blocks until another caller releases one. Sandbox creation happens
    # outside the mutex (it may raise, e.g. ImageMissing).
    def acquire
      create = false
      @mutex.synchronize do
        raise PoolClosed, "pool is closed" if @closed

        if @created < @size
          @created += 1
          create = true
        end
      end

      if create
        begin
          return Sandbox.new(@config)
        rescue StandardError
          @mutex.synchronize { @created -= 1 }
          raise
        end
      end

      # All created sandboxes are busy: block until one is released. (The
      # closed check here mirrors checkout's — a shutdown racing an acquire
      # is still resolved by the release that eventually unblocks this pop.)
      sandbox = @sandboxes.pop
      raise PoolClosed, "pool is closed" if closed?

      sandbox
    end

    def release(sandbox)
      @sandboxes << sandbox
    end

    def record(duration_ms)
      @mutex.synchronize do
        @metrics[:evals] += 1
        @metrics[:total_ms] += duration_ms
      end
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
    end
  end
end
