# frozen_string_literal: true

module SecurityBox
  # Named, reusable profiles: `SecurityBox.register(:name, from: :base) { |c| ... }`
  # stores an immutable Configuration built through the builder DSL; `spawn`
  # resolves a profile and derives per-call overrides with `#with`.
  #
  # Profiles must be registered before they are referenced by `from:`, cannot
  # be redefined (immutability avoids accidental shadowing) and live for the
  # process lifetime; tests can reset the registry with `clear!`.
  module Registry
    MUTEX = Mutex.new

    @profiles = {}

    class << self
      def register(name, from: nil, &block)
        key = normalize(name)
        MUTEX.synchronize do
          raise InvalidConfiguration, "profile #{key.inspect} is already registered" if @profiles.key?(key)

          builder = Configuration::Builder.new
          block&.call(builder)
          @profiles[key] = Configuration.build(**base_of(from), **builder.changes)
        end
      end

      def resolve(name)
        key = normalize(name)
        MUTEX.synchronize do
          @profiles.fetch(key) do
            raise InvalidConfiguration, "unknown profile #{key.inspect}; register it first with SecurityBox.register"
          end
        end
      end

      def profiles
        MUTEX.synchronize { @profiles.dup.freeze }
      end

      def clear!
        MUTEX.synchronize { @profiles.clear }
      end

      private

      def normalize(name)
        unless name.is_a?(Symbol) || name.is_a?(String)
          raise InvalidConfiguration, "profile name must be a Symbol or String, got #{name.class}"
        end

        name.to_sym
      end

      def base_of(from)
        return {} if from.nil?

        key = normalize(from)
        @profiles.fetch(key) do
          raise InvalidConfiguration, "unknown base profile #{key.inspect}; register it before deriving from it"
        end.to_h
      end
    end
  end
end
