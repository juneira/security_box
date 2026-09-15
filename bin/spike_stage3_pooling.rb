#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 3 spike — Q3: pooling allocator (Engine allocation_strategy) vs the
# default on-demand allocator. Measures Store.new+instantiate latency and the
# RSS footprint of live stores.
# Usage: bundle exec ruby bin/spike_stage3_pooling.rb
require "bundler/setup"
require_relative "../lib/security_box"

IMAGE_PATH = File.expand_path("../lib/security_box/assets/security_box.wasm", __dir__).freeze
INTERVAL_MS = 25
MEMORY_SIZE = 512 * 1024 * 1024

def rss_mb
  File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i / 1024.0
end

def vm_size_mb
  File.read("/proc/self/status")[/VmSize:\s+(\d+)/, 1].to_i / 1024.0
end

def engines
  pooling = Wasmtime::PoolingAllocationConfig.new
  pooling.total_memories = 16
  pooling.total_stacks = 16
  pooling.total_tables = 16
  pooling.total_core_instances = 16
  pooling.max_memory_size = MEMORY_SIZE
  {
    default: Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true),
    pooling: Wasmtime::Engine.new(
      consume_fuel: true, epoch_interruption: true, allocation_strategy: pooling
    )
  }
end

engines.each do |label, engine|
  engine.start_epoch_interval(INTERVAL_MS)
  key = engine.precompile_compatibility_key
  module_ = begin
    Wasmtime::Module.deserialize_file(engine, SecurityBox::ModuleCache.cache_path(engine, IMAGE_PATH))
  rescue Wasmtime::Error, TypeError
    nil
  end
  module_ ||= Wasmtime::Module.from_file(engine, IMAGE_PATH)
  linker = Wasmtime::Linker.new(engine).tap { |l| Wasmtime::WASI::P1.add_to_linker_sync(l) }
  puts format("\n== Q3: %s allocator (compat key %s...) ==", label, key[0, 12])

  store_inst = []
  invokes = []
  30.times do
    stdout = String.new
    wasi = Wasmtime::WasiConfig.new
          .set_stdin_string("")
          .set_stdout_buffer(stdout, 1 << 20)
          .set_stderr_buffer(stdout, 1 << 16)
          .set_argv(["ruby", "/src/main.rb"])
          .set_env({})
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    store = Wasmtime::Store.new(engine, wasi_p1_config: wasi, limits: { memory_size: MEMORY_SIZE })
    store.set_fuel(10_000_000_000)
    instance = linker.instantiate(store, module_)
    store_inst << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    store.set_epoch_deadline(5_000 / INTERVAL_MS + 1)
    instance.invoke("_start")
    invokes << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000
    store.close
  end
  p50 = ->(a) { a.sort[a.size / 2] }
  puts format("store+instantiate p50=%.3fms  invoke p50=%.1fms  rss=%.0fMB vm_size=%.0fMB",
              p50.call(store_inst), p50.call(invokes), rss_mb, vm_size_mb)

  # Live-store footprint: 4 simultaneous stores, instances instantiated
  stores = 4.times.map do
    stdout = String.new
    wasi = Wasmtime::WasiConfig.new
          .set_stdin_string("")
          .set_stdout_buffer(stdout, 1 << 20)
          .set_stderr_buffer(stdout, 1 << 16)
          .set_argv(["ruby", "/src/main.rb"])
          .set_env({})
    store = Wasmtime::Store.new(engine, wasi_p1_config: wasi, limits: { memory_size: MEMORY_SIZE })
    store.set_fuel(10_000_000_000)
    linker.instantiate(store, module_)
    store
  end
  puts format("4 live stores: rss=%.0fMB vm_size=%.0fMB", rss_mb, vm_size_mb)
  stores.each(&:close)
  puts format("after close: rss=%.0fMB vm_size=%.0fMB", rss_mb, vm_size_mb)
end
