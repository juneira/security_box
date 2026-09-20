# frozen_string_literal: true

require_relative "eval_run"

module SecurityBox
  # :oneshot mode sandbox — one wasm instance per #eval.
  #
  # The sandbox itself is stateless and cheap: it holds references to the
  # shared runtime artifacts (Engine + compiled Module, both memoized in
  # Runtime) and a WASI Linker. Each #eval runs the shared EvalRun core: an
  # exclusive tmpdir mounted as /work, a per-eval token, fuel + epoch
  # deadlines, and a validated result envelope.
  #
  # Thread safety: Engine/Module/Linker are thread-safe and the eval core is
  # self-contained, so a single Sandbox can be used from multiple threads
  # (evals serialize on the GVL — see RactorPool for real parallelism).
  class Sandbox
    def initialize(configuration = Configuration.build)
      @config = configuration
      @engine = Runtime.engine(epoch_interval_ms: @config.epoch_interval_ms)
      @module = Runtime.module_for(@engine, @config.image_path)
      @linker_mutex = Mutex.new
    end

    # Runs `code` in the sandbox and returns a Result.
    # Per-call options (derived from the configuration without mutating it):
    #   timeout_ms:, fuel:, fuel_ms:, memory_size:, stdout_limit:, stderr_limit:
    def eval(code, **overrides)
      raise ArgumentError, "code is required" if code.nil? || code.empty?

      config = overrides.empty? ? @config : @config.with(**overrides)
      # SecureRandom is not guaranteed Ractor-safe; EvalRun callers generate
      # the token in the main Ractor/thread.
      token = SecureRandom.hex(16)
      EvalRun.run(engine: @engine, module_: @module, linker: linker,
                  config: config, code: code, token: token)
    end

    private

    def linker
      @linker_mutex.synchronize do
        @linker ||= Wasmtime::Linker.new(@engine).tap do |linker|
          Wasmtime::WASI::P1.add_to_linker_sync(linker)
        end
      end
    end
  end
end
