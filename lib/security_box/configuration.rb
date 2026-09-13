# frozen_string_literal: true

module SecurityBox
  # Immutable sandbox configuration. Use .build to create and #with to derive.
  class Configuration
    IMAGE_RELATIVE_DEFAULT = "../../build/security_box.wasm"

    DEFAULTS = {
      image_path: nil, # resolved dynamically (project's build/security_box.wasm)
      fuel: 10_000_000_000,
      timeout_ms: 2_000,
      memory_size: 512 * 1024 * 1024,
      stdout_limit: 1 << 20,
      stderr_limit: 1 << 16,
      epoch_interval_ms: 25,
      env: {}.freeze
    }.freeze

    attr_reader :image_path, :fuel, :timeout_ms, :memory_size,
                :stdout_limit, :stderr_limit, :epoch_interval_ms, :env

    def self.build(**options)
      new(**DEFAULTS.merge(options)).freeze
    end

    def initialize(image_path: nil, fuel:, timeout_ms:, memory_size:,
                   stdout_limit:, stderr_limit:, epoch_interval_ms:, env:)
      @image_path = image_path || default_image_path
      @fuel = Integer(fuel)
      @timeout_ms = Integer(timeout_ms)
      @memory_size = Integer(memory_size)
      @stdout_limit = Integer(stdout_limit)
      @stderr_limit = Integer(stderr_limit)
      @epoch_interval_ms = Integer(epoch_interval_ms)
      @env = env.freeze
      freeze
    end

    def with(**changes)
      self.class.build(**to_h.merge(changes))
    end

    def to_h
      {
        image_path: @image_path,
        fuel: @fuel,
        timeout_ms: @timeout_ms,
        memory_size: @memory_size,
        stdout_limit: @stdout_limit,
        stderr_limit: @stderr_limit,
        epoch_interval_ms: @epoch_interval_ms,
        env: @env
      }
    end

    private

    def default_image_path
      path = File.expand_path(IMAGE_RELATIVE_DEFAULT, __dir__)
      return path if File.exist?(path)

      raise ImageMissing,
            "Imagem do sandbox não encontrada em #{path}. " \
            "Rode `rake security_box:build_image` ou passe image_path na configuração."
    end
  end
end
