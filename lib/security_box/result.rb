# frozen_string_literal: true

module SecurityBox
  # Result of a sandbox execution. Possible statuses:
  #   :ok             — guest code ran and returned a value
  #   :error          — guest code raised an exception
  #   :timeout        — interrupted by epoch (wall clock)
  #   :fuel_exhausted — CPU budget exhausted
  #   :memory_limit   — exceeded the store memory_size
  #   :sandbox_error  — sandbox failure (unexpected trap, missing/invalid envelope)
  class Result
    attr_reader :status, :value, :error, :stdout, :stderr,
                :fuel_used, :duration_ms, :guest_duration_ms

    def initialize(status:, value: nil, error: nil, stdout: "", stderr: "",
                   fuel_used: nil, duration_ms: nil, guest_duration_ms: nil)
      @status = status
      @value = value
      @error = error
      @stdout = stdout
      @stderr = stderr
      @fuel_used = fuel_used
      @duration_ms = duration_ms
      @guest_duration_ms = guest_duration_ms
      freeze
    end

    def ok?
      @status == :ok
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
        guest_duration_ms: @guest_duration_ms
      }
    end
  end
end
