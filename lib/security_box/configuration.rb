# frozen_string_literal: true

require "digest"
require "json"

module SecurityBox
  # Immutable sandbox configuration. Use .build to create and #with to derive.
  class Configuration
    IMAGE_ENV_VAR = "SECURITY_BOX_IMAGE"
    IMAGE_ASSET_RELATIVE = "assets/security_box.wasm"
    IMAGE_DEV_RELATIVE = "../../build/security_box.wasm"

    DEFAULTS = {
      image_path: nil, # resolved dynamically (project's build/security_box.wasm)
      fuel: 10_000_000_000,
      fuel_ms: nil, # rate-based fuel ergonomics (see FUEL_PER_MS); nil = use :fuel
      timeout_ms: 2_000,
      memory_size: 512 * 1024 * 1024,
      stdout_limit: 1 << 20,
      stderr_limit: 1 << 16,
      epoch_interval_ms: 25,
      env: {}.freeze,
      mounts: [].freeze,
      rpcs: {}.freeze
    }.freeze

    # Fuel-per-ms conversion for #fuel_ms, from the stage-3 calibration table
    # (docs/plan/stages/stage_3.md): compute workloads burn 3.2e9–8.4e9 fuel/s;
    # 4e9/s is the conservative floor. The guest boot baseline (~9.1e8 fuel)
    # is added on top so the budget covers boot even for trivial evals.
    FUEL_PER_MS = 4_000_000
    BOOT_FUEL_ALLOWANCE = 1_000_000_000

    attr_reader :image_path, :fuel, :fuel_ms, :timeout_ms, :memory_size,
                :stdout_limit, :stderr_limit, :epoch_interval_ms, :env, :mounts,
                :rpcs

    def self.build(**options)
      new(**DEFAULTS.merge(options)).freeze
    end

    def initialize(image_path: nil, fuel:, fuel_ms:, timeout_ms:, memory_size:,
                   stdout_limit:, stderr_limit:, epoch_interval_ms:, env:, mounts:,
                   rpcs:)
      @image_path = image_path || default_image_path
      @fuel = Integer(fuel)
      @fuel_ms = fuel_ms.nil? ? nil : Integer(fuel_ms)
      @timeout_ms = Integer(timeout_ms)
      @memory_size = Integer(memory_size)
      @stdout_limit = Integer(stdout_limit)
      @stderr_limit = Integer(stderr_limit)
      @epoch_interval_ms = Integer(epoch_interval_ms)
      @env = env.freeze
      @mounts = Mounts.normalize(mounts)
      @rpcs = Rpcs.normalize(rpcs)
      freeze
    end

    # The fuel budget actually applied to each evaluation. When :fuel_ms is
    # set it takes precedence: an approximate millisecond-based budget
    # (fuel_ms × FUEL_PER_MS + boot allowance) instead of a raw fuel count.
    # The epoch timeout remains the mandatory wall-clock backstop either way.
    def effective_fuel
      return fuel unless fuel_ms

      fuel_ms * FUEL_PER_MS + BOOT_FUEL_ALLOWANCE
    end

    # Derives a copy with `changes` applied (never mutates the receiver).
    # Passing both :fuel and a non-nil :fuel_ms is ambiguous and rejected;
    # overriding :fuel on a configuration that uses :fuel_ms is rejected too
    # (pass fuel_ms: nil first to switch to a raw fuel budget).
    def with(**changes)
      if changes.key?(:fuel_ms)
        if changes[:fuel_ms] && changes.key?(:fuel)
          raise InvalidConfiguration,
                "fuel and fuel_ms are mutually exclusive overrides"
        end
      elsif changes.key?(:fuel) && @fuel_ms
        raise InvalidConfiguration,
              "configuration uses fuel_ms (#{fuel_ms}); override fuel_ms or clear it with fuel_ms: nil instead of fuel"
      end

      self.class.build(**to_h.merge(changes))
    end

    def to_h
      {
        image_path: @image_path,
        fuel: @fuel,
        fuel_ms: @fuel_ms,
        timeout_ms: @timeout_ms,
        memory_size: @memory_size,
        stdout_limit: @stdout_limit,
        stderr_limit: @stderr_limit,
        epoch_interval_ms: @epoch_interval_ms,
        env: @env,
        mounts: @mounts,
        rpcs: @rpcs
      }
    end

    # Stable identity of the configuration values (SHA-256 of the normalized
    # hash). Two configurations with equal settings — regardless of how they
    # were built — share the same fingerprint; any #with change produces a
    # different one. Used to key profiles and, later, cached artifacts.
    #
    # RPC handlers are deliberately excluded: they are host-side callables
    # (Procs) with no stable serialized identity, and including them would
    # make the fingerprint depend on object addresses.
    def fingerprint
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end

    def canonical
      to_h.except(:rpcs).merge(env: @env.sort.to_h)
    end

    # Mutable collector for the register DSL. Setter names match the
    # Configuration options (no `=`, e.g. `c.fuel 100`); only changed values
    # are collected and merged over the base profile.
    class Builder
      def initialize
        @changes = {}
      end

      def changes
        @changes
      end

      def image_path(value)
        @changes[:image_path] = value
      end

      def fuel(value)
        raise InvalidConfiguration, "fuel and fuel_ms are mutually exclusive" if @changes.key?(:fuel_ms)

        @changes[:fuel] = value
      end

      # Rate-based fuel ergonomics: sets fuel from an approximate millisecond
      # budget (see Configuration#effective_fuel). Mutually exclusive with
      # an explicit :fuel.
      def fuel_ms(value)
        raise InvalidConfiguration, "fuel and fuel_ms are mutually exclusive" if @changes.key?(:fuel)

        @changes[:fuel_ms] = value
      end

      def timeout_ms(value)
        @changes[:timeout_ms] = value
      end

      def memory_size(value)
        @changes[:memory_size] = value
      end

      def stdout_limit(value)
        @changes[:stdout_limit] = value
      end

      def stderr_limit(value)
        @changes[:stderr_limit] = value
      end

      def epoch_interval_ms(value)
        @changes[:epoch_interval_ms] = value
      end

      # Replaces the guest environment (it is not merged with the base).
      def env(value)
        @changes[:env] = value
      end

      # Mounts a host directory into the guest, read-only by default:
      #   c.mount "host/path" => "/data"
      # Each call appends one mount; use #mount_rw for a writable mount.
      def mount(mapping)
        add_mount(mapping, :read_only)
      end

      # Opt-in writable mount — the only way to expose a writable host path
      # besides the sandbox-private /work tmpdir:
      #   c.mount_rw "host/path" => "/data"
      def mount_rw(mapping)
        add_mount(mapping, :read_write)
      end

      # Registers a guest-callable RPC handler (stage 6):
      #   c.rpc "github.search" => ->(args) { ... }
      #   c.rpc github_search: ->(args) { ... }
      # Each call appends one handler; the per-call :rpcs override replaces
      # the whole set. See SecurityBox::Rpcs for the validation rules.
      def rpc(mapping = nil, **kwargs)
        unless kwargs.empty?
          raise InvalidConfiguration, 'rpc expects exactly one pair: c.rpc "name" => handler' unless kwargs.size == 1 && mapping.nil?

          name, handler = kwargs.first
          mapping = { name.to_s => handler }
        end
        unless mapping.is_a?(Hash) && mapping.size == 1
          raise InvalidConfiguration,
                'rpc expects exactly one pair: c.rpc "name" => handler'
        end

        @changes[:rpcs] = Array(@changes[:rpcs]) + [mapping]
      end

      private

      def add_mount(mapping, mode)
        unless mapping.is_a?(Hash) && mapping.size == 1
          raise InvalidConfiguration,
                'mount expects exactly one pair: c.mount "host/path" => "/data"'
        end

        host, guest = mapping.first
        @changes[:mounts] = Array(@changes[:mounts]) + [{ host: host, guest: guest, mode: mode }]
      end
    end

    private

    # Resolution order (first existing path wins):
    #   1. SECURITY_BOX_IMAGE environment variable
    #   2. the image packed inside this library (gem install or checkout)
    #   3. legacy development output (build/security_box.wasm)
    def default_image_path
      candidates = [ENV[IMAGE_ENV_VAR],
                    File.expand_path(IMAGE_ASSET_RELATIVE, __dir__),
                    File.expand_path(IMAGE_DEV_RELATIVE, __dir__)].compact
      path = candidates.find { |candidate| File.file?(candidate) }
      return path if path

      raise ImageMissing,
            "Sandbox image not found. Tried: #{candidates.join(', ')}. " \
            "Run `rake security_box:build_image`, set #{IMAGE_ENV_VAR}, " \
            "or pass image_path in the configuration."
    end
  end

  # Validated collection of host-folder mounts (stage 5). A mount is a frozen
  # {host:, guest:, mode:} hash; `mounts` in a Configuration is a frozen array
  # of these, so the value survives #with, #fingerprint and Ractor ports.
  #
  # Validation (InvalidConfiguration on any violation):
  #   - mode is :read_only or :read_write (wasmtime silently accepts unknown
  #     symbols, so the mode is checked here, never trusted to the runtime)
  #   - host: non-empty string; relative paths are expanded against Dir.pwd
  #     (existence/directory checks are per-eval, in EvalRun — dirs can vanish)
  #   - guest: absolute, normalized path (no "..", no trailing slash), not "/"
  #   - guest paths must not overlap /work, /usr or /src (exact or nested):
  #     a collision with the embedded VFS is silently shadowed (stage-5 spike:
  #     the mount content is invisible), a mount inside /usr even breaks the
  #     guest boot, and inside /work it would create a read-only subtree
  #   - duplicate guest paths are rejected (wasmtime's last-mount-wins is
  #     silently surprising)
  #   - at most MAX_MOUNTS mounts
  module Mounts
    MODES = %i[read_only read_write].freeze
    RESERVED_GUEST_PATHS = %w[/work /usr /src].freeze
    MAX_MOUNTS = 16

    class << self
      # Validates + normalizes `raw` (an array of {host:, guest:, mode:} hashes
      # or nil) and returns a frozen array of frozen, normalized hashes.
      def normalize(raw)
        return [].freeze if raw.nil?

        raise InvalidConfiguration,
              "mounts must be an Array of {host:, guest:, mode:} hashes, got #{raw.class}" unless raw.is_a?(Array)

        mounts = raw.map { |entry| normalize_entry(entry) }
        check_duplicates(mounts)
        check_reserved(mounts)
        check_count(mounts)
        mounts.freeze
      end

      private

      def normalize_entry(entry)
        unless entry.is_a?(Hash) && entry.keys.sort == %i[guest host mode]
          raise InvalidConfiguration,
                "each mount must be a Hash with exactly :host, :guest and :mode keys, got #{entry.inspect}"
        end

        mode = entry[:mode]
        unless MODES.include?(mode)
          raise InvalidConfiguration,
                "mount mode must be one of #{MODES.map(&:inspect).join(' or ')}, got #{mode.inspect}"
        end

        { host: normalize_host(entry[:host]),
          guest: normalize_guest(entry[:guest]),
          mode: mode }.freeze
      end

      def normalize_host(host)
        unless host.is_a?(String) && !host.empty?
          raise InvalidConfiguration, "mount host path must be a non-empty String, got #{host.inspect}"
        end

        File.expand_path(host).freeze
      end

      def normalize_guest(guest)
        unless guest.is_a?(String) && !guest.empty?
          raise InvalidConfiguration, "mount guest path must be a non-empty String, got #{guest.inspect}"
        end
        unless guest.start_with?("/")
          raise InvalidConfiguration, "mount guest path must be absolute, got #{guest.inspect}"
        end

        guest = guest.chomp("/")
        if guest.empty? || File.expand_path(guest, "/") != guest
          raise InvalidConfiguration,
                "mount guest path must be a normalized absolute path (no '..', '.' or trailing '/'), got #{guest.inspect}"
        end
        raise InvalidConfiguration, "mount guest path contains a NUL byte" if guest.include?("\0")

        guest.freeze
      end

      def check_duplicates(mounts)
        guests = mounts.map { |mount| mount[:guest] }
        duplicate = guests.find { |guest| guests.count(guest) > 1 }
        return unless duplicate

        raise InvalidConfiguration, "duplicate guest mount path #{duplicate.inspect}"
      end

      def check_reserved(mounts)
        mounts.each do |mount|
          guest = mount[:guest]
          conflict = RESERVED_GUEST_PATHS.find do |reserved|
            guest == reserved || guest.start_with?("#{reserved}/") || reserved.start_with?("#{guest}/")
          end
          next unless conflict

          raise InvalidConfiguration,
                "mount guest path #{guest.inspect} overlaps the reserved path #{conflict.inspect}"
        end
      end

      def check_count(mounts)
        return if mounts.size <= MAX_MOUNTS

        raise InvalidConfiguration,
              "too many mounts (#{mounts.size}); the limit is #{MAX_MOUNTS}"
      end
    end
  end

  # Validated collection of guest-callable RPC handlers (stage 6). A
  # handler is a name => callable pair; `rpcs` in a Configuration is a
  # frozen hash, so the value survives #with and #to_h.
  #
  # Handlers execute on the host (between guest steps, inside the RPC
  # import) and are therefore host-only state: they are excluded from
  # #fingerprint, and a Configuration carrying Procs is not
  # Ractor-shareable — RactorPool rejects rpcs and strips them before a
  # config crosses a Ractor boundary.
  #
  # Validation (InvalidConfiguration on any violation):
  #   - raw is a Hash of name => handler, or an Array of one-pair hashes
  #     (the register DSL appends one pair per c.rpc call)
  #   - name: non-empty String, unique
  #   - handler: anything responding to #call; it receives the
  #     JSON-parsed request args and must return a JSON-serializable
  #     value (non-serializable results surface as inspect strings)
  #   - at most MAX_RPCS handlers
  module Rpcs
    MAX_RPCS = 64

    class << self
      # Validates + normalizes `raw` and returns a frozen
      # name => handler hash.
      def normalize(raw)
        return {}.freeze if raw.nil?

        pairs = case raw
                when Hash then raw.entries
                when Array
                  unless raw.all? { |entry| entry.is_a?(Hash) && entry.size == 1 }
                    raise InvalidConfiguration,
                          "rpcs must be a Hash or an Array of one-pair hashes, " \
                          "got #{raw.inspect[0, 80]}"
                  end
                  raw.flat_map(&:entries)
                else
                  raise InvalidConfiguration,
                        "rpcs must be a Hash of name => handler, got #{raw.class}"
                end

        rpcs = {}
        pairs.each do |name, handler|
          unless name.is_a?(String) && !name.empty?
            raise InvalidConfiguration, "rpc name must be a non-empty String, got #{name.inspect}"
          end
          unless handler.respond_to?(:call)
            raise InvalidConfiguration,
                  "rpc handler for #{name.inspect} must respond to #call, " \
                  "got #{handler.inspect[0, 80]}"
          end
          raise InvalidConfiguration, "duplicate rpc name #{name.inspect}" if rpcs.key?(name)

          rpcs[name] = handler
        end
        return rpcs.freeze if rpcs.size <= MAX_RPCS

        raise InvalidConfiguration,
              "too many rpcs (#{rpcs.size}); the limit is #{MAX_RPCS}"
      end
    end
  end
end
