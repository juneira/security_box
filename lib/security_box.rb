# frozen_string_literal: true

require_relative "security_box/version"
require_relative "security_box/errors"
require_relative "security_box/configuration"
require_relative "security_box/result"
require_relative "security_box/runtime"
require_relative "security_box/sandbox"

module SecurityBox
  # Convenience shortcut:
  #   SecurityBox.eval("1 + 1")            # => Result
  #   SecurityBox.eval("1", fuel: 100)     # per-call overrides
  def self.eval(code, **overrides)
    Sandbox.new.eval(code, **overrides)
  end

  # Prepares the shared runtime artifacts (Engine + compiled Module) ahead of
  # time so the first #eval skips the cold module compilation (~15s per
  # process). #eval warms these caches lazily on first use, so calling
  # warmup is a pure optimization: behavior and results are identical
  # without it. Accepts the same options as Configuration.build (only
  # image_path and epoch_interval_ms affect what gets warmed). Returns the
  # warmed Sandbox; safe to call multiple times.
  def self.warmup(**options)
    Sandbox.new(Configuration.build(**options))
  end
end
