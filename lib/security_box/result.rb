# frozen_string_literal: true

module SecurityBox
  # Result of a sandbox execution. Possible statuses:
  #   :ok             — guest code ran and returned a value
  #   :error          — guest code raised an exception
  #   :timeout        — interrupted by epoch (wall clock)
  #   :fuel_exhausted — CPU budget exhausted
  #   :memory_limit   — exceeded the store memory_size
  #   :sandbox_error  — sandbox failure (unexpected trap, missing/invalid envelope)
  #
  # `rpcs` (stage 6): the host-side transcript of guest RPC calls, one
  # frozen {"name", "args", "ok", "result"|"error"} entry per call, or nil
  # when no rpcs were configured (or none were called).
  class Result
    attr_reader :status, :value, :error, :stdout, :stderr,
                :fuel_used, :duration_ms, :guest_duration_ms, :rpcs

    def initialize(status:, value: nil, error: nil, stdout: "", stderr: "",
                   fuel_used: nil, duration_ms: nil, guest_duration_ms: nil,
                   rpcs: nil)
      @status = status
      @value = value
      @error = error
      @stdout = stdout
      @stderr = stderr
      @fuel_used = fuel_used
      @duration_ms = duration_ms
      @guest_duration_ms = guest_duration_ms
      @rpcs = rpcs
      freeze
    end

    def ok?
      @status == :ok
    end

    # Factory for the "the worker never answered" sandbox failure (dead or
    # stalled Ractor worker, or the pop deadline elapsed).
    def self.worker_unavailable(worker_index)
      new(status: :sandbox_error,
          stderr: "security_box: RactorPool worker #{worker_index} did not answer\n")
    end

    def to_h
      {
        status: @status,
        value: @value,
        error: @error,
        stdout: @stdout,
        stderr: @stderr,
        fuel_used: @fuel_used,
        duration_ms: @duration_ms,
        guest_duration_ms: @guest_duration_ms,
        rpcs: @rpcs
      }
    end
  end
end
