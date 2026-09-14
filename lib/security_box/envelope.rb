# frozen_string_literal: true

require "json"

module SecurityBox
  # Host-side validation of the guest result envelope.
  #
  # The guest reports its result either via /work/out.json or, when /work is
  # unavailable, via a sentinel line on stdout (format:
  # `__SECURITY_BOX_RESULT__:<token>:<json>`). Both embed the per-eval random
  # token the host generated. An envelope is trusted only when it parses, the
  # token matches and every field has the expected type; otherwise nil is
  # returned and the execution is reported as a sandbox failure.
  module Envelope
    # Keep in sync with lib/security_box/guest/main.rb.
    SENTINEL = "__SECURITY_BOX_RESULT__"

    class << self
      # Parses `raw` (JSON text) and validates it against `token`.
      # Returns the envelope Hash or nil when invalid/untrusted.
      def parse(raw, token)
        return nil unless raw.is_a?(String) && token.is_a?(String) && !token.empty?

        envelope = JSON.parse(raw)
        return nil unless valid?(envelope, token)

        envelope
      rescue JSON::ParserError, TypeError, ArgumentError
        nil
      end

      # Scans captured stdout for exactly one sentinel line carrying `token`.
      # Zero or multiple sentinel lines (e.g. a guest forging an extra one)
      # yield nil.
      def from_stdout(stdout, token)
        prefix = "#{SENTINEL}:"
        lines = stdout.to_s.split("\n").select { |line| line.start_with?(prefix) }
        return nil unless lines.size == 1

        _sentinel, _embedded_token, json = lines.first.split(":", 3)
        parse(json, token)
      end

      private

      def valid?(envelope, token)
        return false unless envelope.is_a?(Hash)
        return false unless [true, false].include?(envelope["ok"])
        return false unless envelope["token"] == token

        if envelope["ok"]
          return false unless envelope.key?("value")
        else
          error = envelope["error"]
          return false unless error.is_a?(Hash)
          return false unless error["class"].is_a?(String)
          return false unless error["message"].is_a?(String)
        end

        duration = envelope["duration_ms"]
        duration.nil? || duration.is_a?(Numeric)
      end
    end
  end
end
