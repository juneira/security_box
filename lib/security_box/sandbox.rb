# frozen_string_literal: true

require "json"
require "securerandom"
require "tmpdir"

module SecurityBox
  # :oneshot mode sandbox — one wasm instance per #eval.
  #
  # Flow:
  #   1. exclusive tmpdir mounted as /work (read-write)
  #   2. user code written to /work/code.rb
  #   3. a per-eval random token is passed via ENV (SB_TOKEN); the guest
  #      prelude captures it and scrubs ENV before user code runs
  #   4. guest (/src/main.rb) evaluates the code and writes /work/out.json,
  #      embedding the token (stdout sentinel fallback does the same)
  #   5. host reads the envelope, validates schema + token (untrusted results
  #      become a sandbox failure) and returns a Result
  class Sandbox
    GUEST_ENTRYPOINT = "/src/main.rb"
    RESULT_FILE = "out.json"
    CODE_FILE = "code.rb"
    TOKEN_ENV_VAR = "SB_TOKEN"

    def initialize(configuration = Configuration.build)
      @config = configuration
      @engine = Runtime.engine(epoch_interval_ms: @config.epoch_interval_ms)
      @module = Runtime.module_for(@engine, @config.image_path)
    end

    # Runs `code` in the sandbox and returns a Result.
    # Per-call options (derived from the configuration without mutating it):
    #   timeout_ms:, fuel:, memory_size:, stdout_limit:, stderr_limit:
    def eval(code, **overrides)
      raise ArgumentError, "code is required" if code.nil? || code.empty?

      config = overrides.empty? ? @config : @config.with(**overrides)
      stdout = +""
      stderr = +""
      token = SecureRandom.hex(16)
      t0 = monotonic_ms

      Dir.mktmpdir("security_box") do |workdir|
        File.write(File.join(workdir, CODE_FILE), code)
        envelope = nil
        status = nil
        fuel_used = nil

        store = Wasmtime::Store.new(
          @engine,
          wasi_p1_config: build_wasi(workdir, stdout, stderr, config, token),
          limits: { memory_size: config.memory_size }
        )
        begin
          store.set_fuel(config.fuel)
          instance = build_linker.instantiate(store, @module)
          store.set_epoch_deadline(epoch_ticks(config))
          status = invoke_guest(instance, store)
          fuel_used = config.fuel - store.get_fuel
          envelope = read_envelope(workdir, stdout, token)
        ensure
          store.close
        end

        build_result(status, envelope, stdout, stderr, fuel_used, monotonic_ms - t0)
      end
    end

    private

    def build_wasi(workdir, stdout, stderr, config, token)
      Wasmtime::WasiConfig.new
        .set_stdin_string("")
        .set_stdout_buffer(stdout, config.stdout_limit)
        .set_stderr_buffer(stderr, config.stderr_limit)
        .set_argv(["ruby", GUEST_ENTRYPOINT])
        .set_env(config.env.merge(TOKEN_ENV_VAR => token))
        .set_mapped_directory(workdir, "/work", :read_write)
    end

    def build_linker
      @linker ||= Wasmtime::Linker.new(@engine).tap do |linker|
        Wasmtime::WASI::P1.add_to_linker_sync(linker)
      end
    end

    def epoch_ticks(config)
      [config.timeout_ms / config.epoch_interval_ms + 1, 1].max
    end

    def invoke_guest(instance, store)
      instance.invoke("_start")
      :ok
    rescue Wasmtime::WasiExit => e
      handle_wasi_exit(e, store)
    rescue Wasmtime::Trap => e
      map_trap(e, store)
    rescue Wasmtime::Error
      # Unexpected runtime error (non-trap): treated as a sandbox failure.
      :sandbox_error
    end

    def handle_wasi_exit(exit_error, store)
      # The guest rescues SystemExit; a WasiExit here means exit! or a guest crash
      # before the envelope was written.
      store.linear_memory_limit_hit? ? :memory_limit : :sandbox_error
    end

    def map_trap(trap, store)
      case trap.code
      when :interrupt then :timeout
      when :out_of_fuel then :fuel_exhausted
      when :memory_out_of_bounds then :memory_limit
      else
        store.linear_memory_limit_hit? ? :memory_limit : :sandbox_error
      end
    end

    def read_envelope(workdir, stdout, token)
      # Preferred channel: /work/out.json. Fallback: sentinel line on stdout.
      # Both go through the same strict validation (schema + token).
      Envelope.parse(read_result_file(workdir), token) ||
        Envelope.from_stdout(stdout, token)
    end

    def read_result_file(workdir)
      File.read(File.join(workdir, RESULT_FILE))
    rescue SystemCallError
      nil
    end

    def build_result(status, envelope, stdout, stderr, fuel_used, duration_ms)
      if envelope.nil?
        status = :sandbox_error if status == :ok
        return Result.new(
          status: status, stdout: stdout, stderr: stderr,
          fuel_used: fuel_used, duration_ms: duration_ms
        )
      end

      guest_error = envelope["error"]
      if envelope["ok"]
        Result.new(
          status: status, value: envelope["value"], stdout: stdout, stderr: stderr,
          fuel_used: fuel_used, duration_ms: duration_ms,
          guest_duration_ms: envelope["duration_ms"]
        )
      else
        Result.new(
          status: :error, error: guest_error, stdout: stdout, stderr: stderr,
          fuel_used: fuel_used, duration_ms: duration_ms,
          guest_duration_ms: envelope["duration_ms"]
        )
      end
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
    end
  end
end
