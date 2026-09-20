# frozen_string_literal: true

require "wasmtime"

require_relative "module_cache"

module SecurityBox
  # Registry of heavyweight artifacts shared across sandboxes:
  # - Engine (one per runtime configuration; owns the epoch timer)
  # - Compiled Module (one per engine+image)
  #
  # Module compilation is slow (~15s the first time per process); the compiled
  # artifact is persisted via ModuleCache so later processes deserialize it
  # from disk instead of recompiling.
  module Runtime
    MUTEX = Mutex.new

    @engines = {}
    @modules = {}

    class << self
      def engine(epoch_interval_ms:)
        MUTEX.synchronize do
          @engines[epoch_interval_ms] ||= build_engine(epoch_interval_ms)
        end
      end

      def module_for(engine, image_path)
        MUTEX.synchronize do
          @modules[[engine.object_id, image_path]] ||= begin
            ModuleCache.load_module(engine, image_path) ||
              ModuleCache.compile_and_store(engine, image_path)
          end
        end
      end

      def clear!
        MUTEX.synchronize do
          @engines.clear
          @modules.clear
        end
      end

      # Builds a dedicated (not memoized) Engine + Module pair prepared for
      # use across Ractors: the epoch timer is started and the precompile
      # key is touched BEFORE freezing, then both artifacts are made
      # Ractor-shareable (stage-3 Q2 "Plan C"). The pair is not stored in the
      # class memos — freezing shared artifacts would affect every Sandbox —
      # so each RactorPool pays one module deserialize (~0.5s via the disk
      # cache). Callers must treat the returned pair as immutable.
      def build_shareable(image_path:, epoch_interval_ms:)
        engine = build_engine(epoch_interval_ms)
        module_ = ModuleCache.load_module(engine, image_path) ||
                  ModuleCache.compile_and_store(engine, image_path)
        engine.precompile_compatibility_key # touch before make_shareable
        Ractor.make_shareable(engine)
        Ractor.make_shareable(module_)
        [engine, module_]
      end

      private

      def build_engine(epoch_interval_ms)
        engine = Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true)
        if engine.respond_to?(:start_epoch_interval)
          engine.start_epoch_interval(epoch_interval_ms)
        else
          timer = Thread.new do
            loop do
              sleep(epoch_interval_ms / 1000.0)
              engine.increment_epoch
            end
          end
          timer.name = "security_box-epoch-timer"
        end
        engine
      end
    end
  end
end
