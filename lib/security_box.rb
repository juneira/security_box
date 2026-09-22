# frozen_string_literal: true

require_relative "security_box/version"
require_relative "security_box/errors"
require_relative "security_box/configuration"
require_relative "security_box/registry"
require_relative "security_box/result"
require_relative "security_box/module_cache"
require_relative "security_box/runtime"
require_relative "security_box/envelope"
require_relative "security_box/guest_rpc"
require_relative "security_box/sandbox"
require_relative "security_box/eval_run"
require_relative "security_box/pool"
require_relative "security_box/ractor_pool"

module SecurityBox
  # Convenience shortcut:
  #   SecurityBox.eval("1 + 1")            # => Result
  #   SecurityBox.eval("1", fuel: 100)     # per-call overrides
  def self.eval(code, **overrides)
    Sandbox.new.eval(code, **overrides)
  end

  # Registers a named, reusable profile (see Registry).
  #   SecurityBox.register(:lean, from: :default) { |c| c.fuel 5_000_000 }
  def self.register(name, from: nil, &block)
    Registry.register(name, from: from, &block)
  end

  # Builds a Sandbox from a registered profile, a Configuration, or the
  # defaults:
  #   SecurityBox.spawn(:lean)                  # named profile
  #   SecurityBox.spawn(:lean, fuel: 1_000)     # profile + per-call overrides
  #   SecurityBox.spawn(my_config)              # explicit configuration
  #   SecurityBox.spawn                         # default configuration
  def self.spawn(profile = nil, **overrides)
    config = case profile
             when nil then Configuration.build(**overrides)
             when Symbol, String
               resolved = Registry.resolve(profile)
               overrides.empty? ? resolved : resolved.with(**overrides)
             when Configuration
               overrides.empty? ? profile : profile.with(**overrides)
             else
               raise ArgumentError,
                     "profile must be a registered name or a Configuration, got #{profile.class}"
             end
    Sandbox.new(config)
  end

  # Builds a Pool of :oneshot sandboxes (bounded concurrency on threads).
  # NOTE: evals serialize on the GVL — see RactorPool for parallelism.
  #   SecurityBox.pool(:lean, size: 4).eval("1 + 1")
  def self.pool(profile = nil, size: 4, **overrides)
    Pool.new(profile, size: size, **overrides)
  end

  # Builds a RactorPool (real parallelism: worker Ractors sharing one
  # Engine+Module). Costs one module deserialize at creation (~0.5s via the
  # disk cache); each eval still pays the guest boot (~240ms).
  #   SecurityBox.ractor_pool(:lean, size: 4).eval("1 + 1")
  def self.ractor_pool(profile = nil, size: 4, **overrides)
    RactorPool.new(profile, size: size, **overrides)
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
