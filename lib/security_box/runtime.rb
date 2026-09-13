# frozen_string_literal: true

require "wasmtime"

module SecurityBox
  # Registry of heavyweight artifacts shared across sandboxes:
  # - Engine (one per runtime configuration; owns the epoch timer)
  # - Compiled Module (one per engine+image)
  #
  # Module compilation is slow (~15s the first time per process); the disk cache
  # (Module#serialize) lands in Stage 2.
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
          @modules[[engine.object_id, image_path]] ||=
            Wasmtime::Module.from_file(engine, image_path)
        end
      end

      def clear!
        MUTEX.synchronize do
          @engines.clear
          @modules.clear
        end
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
