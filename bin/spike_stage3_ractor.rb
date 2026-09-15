#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 3 spike — Q2: Ractor parallelism (stage-1 Q9 found `invoke` holds the GVL).
# Usage: bundle exec ruby bin/spike_stage3_ractor.rb
require "bundler/setup"
require_relative "../lib/security_box"

IMAGE_PATH = File.expand_path("../lib/security_box/assets/security_box.wasm", __dir__).freeze
INTERVAL_MS = 25

def rss_mb
  File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i / 1024.0
end

# A module compiled by one Engine only works with that engine; each Ractor
# therefore builds its own runtime, deserializing the compiled artifact from
# the stage-2 disk cache (~0.5s instead of ~15s). The module cache path is
# computed in the main Ractor: class-level memos are not Ractor-accessible.
def build_runtime(image_path, module_path)
  engine = Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true)
  engine.start_epoch_interval(INTERVAL_MS)
  module_ = Wasmtime::Module.deserialize_file(engine, module_path)
  linker = Wasmtime::Linker.new(engine).tap { |l| Wasmtime::WASI::P1.add_to_linker_sync(l) }
  [engine, module_, linker]
end

# One full eval on a private runtime; returns {value:, ms:}.
def eval_with(runtime, code, timeout_ms: 5_000, fuel: 10_000_000_000)
  engine, module_, linker = runtime
  stdout = String.new
  wasi = Wasmtime::WasiConfig.new
        .set_stdin_string("")
        .set_stdout_buffer(stdout, 1 << 20)
        .set_stderr_buffer(stdout, 1 << 16)
        .set_argv(["ruby", "/src/main.rb"])
        .set_env({})
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  store = Wasmtime::Store.new(engine, wasi_p1_config: wasi, limits: { memory_size: 512 * 1024 * 1024 })
  store.set_fuel(fuel)
  instance = linker.instantiate(store, module_)
  store.set_epoch_deadline(timeout_ms / INTERVAL_MS + 1)
  status = begin
    instance.invoke("_start")
    :ok
  rescue Wasmtime::WasiExit
    :wasi_exit
  rescue Wasmtime::Trap => e
    e.code
  end
  ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
  store.close
  { status: status, ms: ms.round }
end

puts "== Q2: Ractor parallelism =="
puts "ruby #{RUBY_VERSION} | rss before=#{rss_mb.round}MB"
puts "host cpus: #{`nproc`.chomp}"

image_path = IMAGE_PATH.dup.freeze
module_path = SecurityBox::ModuleCache.cache_path(
  Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true), image_path
).freeze
raise "no compiled module in the disk cache; run the suite once first" unless module_path && File.file?(module_path)

# Warm the disk cache in the main process (and confirm the runtime works here)
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
runtime = build_runtime(image_path, module_path)
puts "main runtime built (module deserialize): #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round}ms"
puts "sanity: #{eval_with(runtime, "40 + 2").inspect}"

CODE = "i = 0; while i < 2_000_000; i += 1; end; i"

# Shareability probe (Plan A): can one Engine/Module be shared across Ractors?
puts "\n-- Plan A: share one Engine+Module across Ractors --"
engine = Wasmtime::Engine.new
begin
  Ractor.make_shareable(engine)
  puts "Engine.make_shareable: OK"
rescue Ractor::Error => e
  puts "Engine.make_shareable: #{e.class}: #{e.message[0, 120]}"
end
mod = Wasmtime::Module.new(engine, "(module (memory 1))")
begin
  Ractor.make_shareable(mod)
  puts "Module.make_shareable: OK"
rescue Ractor::Error => e
  puts "Module.make_shareable: #{e.class}: #{e.message[0, 120]}"
end

# Plan B: N Ractors × private runtime each
puts "\n-- Plan B: N Ractors, each with a private runtime --"
[2, 4].each do |n|
  code = CODE
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ractors = n.times.map do
    Ractor.new(code, image_path, module_path, name: "worker") do |snippet, img, mpath|
      rt = build_runtime(img, mpath)
      results = 3.times.map { eval_with(rt, snippet) }
      [results, rss_mb.round]
    end
  end
  out = ractors.map(&:value)
  wall = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
  serial = out.sum { |results, _| results.sum { |r| r[:ms] } }
  statuses = out.map { |results, _| results.map { |r| r[:status] }.join(",") }
  puts format("n=%d wall=%.0fms serial_sum=%.0fms ratio=%.2f rss_end=%dMB statuses=%s",
              n, wall, serial, wall / serial, rss_mb.round, statuses.join(" | "))
end

# Plan C: one Engine + Module made Ractor-shareable; Ractors only pay
# Store.new + instantiate (~0.2ms) per eval. The engine epoch timer and
# precompile key must be initialized BEFORE make_shareable (freezing).
puts "\n-- Plan C: shared Engine+Module (make_shareable) --"
shared_engine = Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true)
shared_engine.start_epoch_interval(INTERVAL_MS)
shared_module = Wasmtime::Module.deserialize_file(shared_engine, module_path)
shared_engine.precompile_compatibility_key
Ractor.make_shareable(shared_engine)
Ractor.make_shareable(shared_module)
puts "engine+module made shareable"

[2, 4].each do |n|
  code = CODE
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  ractors = n.times.map do
    Ractor.new(code, shared_engine, shared_module, name: "worker") do |snippet, eng, mod|
      linker = Wasmtime::Linker.new(eng).tap { |l| Wasmtime::WASI::P1.add_to_linker_sync(l) }
      results = 3.times.map { eval_with([eng, mod, linker], snippet) }
      [results, rss_mb.round]
    end
  end
  out = ractors.map(&:value)
  wall = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
  serial = out.sum { |results, _| results.sum { |r| r[:ms] } }
  statuses = out.map { |results, _| results.map { |r| r[:status] }.join(",") }
  puts format("n=%d wall=%.0fms serial_sum=%.0fms ratio=%.2f rss_end=%dMB statuses=%s",
              n, wall, serial, wall / serial, rss_mb.round, statuses.join(" | "))
end
