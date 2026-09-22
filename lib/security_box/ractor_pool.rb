# frozen_string_literal: true

require "securerandom"

module SecurityBox
  # Pool of Ractor workers sharing one Engine + compiled Module (stage-3 Q2
  # "Plan C"): the pool builds a dedicated runtime pair, makes it
  # Ractor-shareable, and N worker Ractors each keep a private Linker. Per
  # eval a worker creates Store + Instance (~0.2ms), applies the request's
  # fuel/epoch/memory limits (safe: the worker owns its store), and invokes.
  #
  # This is the only supported way to run evaluations in parallel: `invoke`
  # holds the GVL for the whole guest lifetime (stage-4 Q1), so threads
  # serialize (see Pool).
  #
  # Protocol (Ruby 3.4+/4.0 Ractor port model):
  # - eval builds a request {id, code, token, config} and sends it to the
  #   worker with the fewest in-flight requests (worker << request);
  # - workers run the shared EvalRun core and push
  #   {id, worker, result} back to the main Ractor (Ractor.main << ...);
  # - a main-side collector thread receives from the main Ractor port and
  #   routes each result to the Queue of the thread waiting for it (results
  #   are matched by request id; this thread must be the only main-port
  #   receiver in the process);
  # - every request terminates (epoch + fuel), and a pop deadline converts a
  #   dead worker into a :sandbox_error result instead of a hang.
  #
  # Trade-offs (measured, stage-3 Q2 / stage-4): one module deserialize per
  # pool (~0.5s via the disk cache); each worker's eval still pays the
  # ~240ms guest boot. Ratios at 2/4 Ractors on 6 cores: 0.56 / 0.28 wall vs
  # serial, RSS ~111MB with the shared runtime.
  #
  # Usage:
  #   pool = SecurityBox::RactorPool.new(:lean, size: 4)
  #   pool.eval("1 + 1")     # => Result
  #   pool.shutdown
  class RactorPool
    STOP = :security_box_stop
    POP_SLACK_MS = 10_000

    attr_reader :size

    def initialize(profile = nil, size: 4, **options)
      @size = Integer(size)
      raise ArgumentError, "size must be >= 1" if @size < 1

      @config = resolve_config(profile, options)
      raise InvalidConfiguration, "rpcs are not supported on RactorPool (handlers cannot cross a Ractor boundary)" unless @config.rpcs.empty?

      @mutex = Mutex.new
      @pending = {} # request id => Queue
      @in_flight = Array.new(@size, 0)
      @closed = false
      @next_id = 0
      @metrics = { evals: 0, total_ms: 0.0, timeouts: 0 }

      engine, module_ = Runtime.build_shareable(
        image_path: @config.image_path,
        epoch_interval_ms: @config.epoch_interval_ms
      )
      @workers = Array.new(@size) do |index|
        build_worker(engine, module_, index)
      end
      start_collector_thread
    end

    # Runs `code` on one of the workers and blocks until its Result arrives.
    # Per-call overrides follow Sandbox#eval (same Configuration#with rules).
    #
    # RPC handlers are not supported here (v1): they are host Procs that
    # cannot cross a Ractor boundary. A configuration with rpcs raises
    # InvalidConfiguration at construction.
    def eval(code, **overrides)
      raise PoolClosed, "pool is closed" if closed?

      config = overrides.empty? ? @config : @config.with(**overrides)
      raise InvalidConfiguration, "rpcs are not supported on RactorPool (handlers cannot cross a Ractor boundary)" unless config.rpcs.empty?

      request = {
        id: next_id,
        code: code,
        token: SecureRandom.hex(16),
        config: config
      }
      queue = Queue.new
      worker_index = @mutex.synchronize do
        @pending[request[:id]] = queue
        index = @in_flight.each_with_index.min_by { |count, _| count }.last
        @in_flight[index] += 1
        index
      end

      begin
        @workers[worker_index] << request
        deadline_ms = config.timeout_ms + POP_SLACK_MS
        result = queue.pop(timeout: deadline_ms / 1000.0)
        raise ThreadError, "no result" if result.nil? # Queue#pop timeout
        record(result)
        result
      rescue ThreadError, Ractor::ClosedError
        # Worker died, stalled beyond the deadline, or was shut down mid-flight:
        # report instead of hang or leak the error.
        @mutex.synchronize { @metrics[:timeouts] += 1 }
        Result.worker_unavailable(worker_index)
      ensure
        @mutex.synchronize do
          @in_flight[worker_index] -= 1 if @in_flight[worker_index] > 0
          @pending.delete(request[:id])
        end
      end
    end

    # Snapshot of the counters: {size:, evals:, total_ms:, avg_ms:, timeouts:}.
    def metrics
      @mutex.synchronize do
        evals = @metrics[:evals]
        { size: @size, evals: evals, total_ms: @metrics[:total_ms].round(2),
          avg_ms: evals.zero? ? 0.0 : (@metrics[:total_ms] / evals).round(2),
          timeouts: @metrics[:timeouts] }
      end
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    # Asks all workers to stop. Evals already in flight finish; new evals
    # raise PoolClosed.
    def shutdown
      @mutex.synchronize { @closed = true }
      @workers.each { |worker| worker << STOP }
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

    def build_worker(engine, module_, worker_index)
      Ractor.new(engine, module_, worker_index, name: "security_box-worker-#{worker_index}") do |eng, mod, index|
        linker = Wasmtime::Linker.new(eng).tap do |l|
          Wasmtime::WASI::P1.add_to_linker_sync(l)
          # The image statically links the sb_rpc extension, so the
          # "sb"/"call" import must be defined even though configs are
          # stripped of rpcs before crossing the Ractor boundary
          # (guest calls get a rescuable error via caller.store_data).
          SecurityBox::GuestRpc.define_import(l)
        end
        loop do
          request = Ractor.receive
          break if request == :security_box_stop

          begin
            result = SecurityBox::EvalRun.run(
              engine: eng, module_: mod, linker: linker,
              config: request[:config], code: request[:code], token: request[:token]
            )
          rescue StandardError => e
            result = SecurityBox::Result.new(
              status: :sandbox_error,
              stderr: "security_box: worker #{index} crashed: #{e.class}: #{e.message}\n"
            )
          end
          Ractor.main << { id: request[:id], worker: index, result: result }
        end
        Ractor.main << { type: :stopped, worker: index }
      end
    end

    def start_collector_thread
      @collector_thread = Thread.new do
        stopped = 0
        loop do
          message = Ractor.receive
          if message[:type] == :stopped
            stopped += 1
            break if stopped >= @size
          else
            route(message)
          end
        end
      end
      @collector_thread.name = "security_box-collector"
    end

    def route(message)
      @mutex.synchronize do
        @in_flight[message[:worker]] -= 1 if @in_flight[message[:worker]] > 0
        queue = @pending.delete(message[:id])
        queue << message[:result] if queue
      end
    end

    def record(result)
      @mutex.synchronize do
        @metrics[:evals] += 1
        @metrics[:total_ms] += result.duration_ms.to_f
      end
    end

    def next_id
      @mutex.synchronize do
        @next_id += 1
        @next_id
      end
    end
  end
end
