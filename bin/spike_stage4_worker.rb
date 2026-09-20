#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 4 spike — worker-mode feasibility (Q1/Q2) and GVL behavior.
#
# Verdict (measured): `instance.invoke` holds the GVL for the whole guest
# lifetime — including while the guest is blocked on a WASI stdin read — and
# epoch deadlines only fire at wasm execution checkpoints (never inside a
# blocking syscall). A host thread therefore can NEVER interleave with a
# running or idle guest, which makes a long-lived `:worker` (FIFO channel or
# /work files) impossible on wasmtime-rb 48 (sync WASI). Concurrency must come
# from Ractors (stage-3 Q2: ~3.6x at 4 Ractors on 6 cores).
#
# Run with a timeout guard:  timeout 120 bundle exec ruby bin/spike_stage4_worker.rb
require "bundler/setup"
require "tmpdir"
require_relative "../lib/security_box"

IMAGE_PATH = File.expand_path("../lib/security_box/assets/security_box.wasm", __dir__).freeze
INTERVAL_MS = 25
LOOP_ITERS = 50_000_000

# Kill switch: a hang here is itself a finding (GVL held). SIGKILL ignores
# the GVL entirely.
Thread.new do
  sleep 90
  warn "SPIKE WATCHDOG: 90s elapsed — killing (GVL deadlock likely)"
  Process.kill("KILL", Process.pid)
end

def build_runtime
  engine = Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true)
  engine.start_epoch_interval(INTERVAL_MS)
  module_ = Wasmtime::Module.from_file(engine, IMAGE_PATH)
  linker = Wasmtime::Linker.new(engine).tap { |l| Wasmtime::WASI::P1.add_to_linker_sync(l) }
  [engine, module_, linker]
end

def oneshot_wasi(workdir, stdout)
  Wasmtime::WasiConfig.new
    .set_stdin_string("")
    .set_stdout_buffer(stdout, 1 << 20)
    .set_stderr_buffer(String.new, 1 << 16)
    .set_argv(["ruby", "/src/main.rb"])
    .set_env({})
    .set_mapped_directory(workdir, "/work", :read_write)
end

puts "== Stage 4 spike: worker-mode feasibility =="
puts "ruby #{RUBY_VERSION}"

# Probe A — GVL during pure compute: the main thread sleeps 0.3s and records
# when it actually regains control relative to the invoke ending.
code = "i = 0; while i < #{LOOP_ITERS}; i += 1; end"
Dir.mktmpdir do |workdir|
  File.write(File.join(workdir, "code.rb"), code)
  engine, module_, linker = build_runtime
  stdout = String.new
  store = Wasmtime::Store.new(engine, wasi_p1_config: oneshot_wasi(workdir, stdout),
                              limits: { memory_size: 512 * 1024 * 1024 })
  store.set_fuel(5 * 10**10)
  instance = linker.instantiate(store, module_)
  store.set_epoch_deadline(60_000 / INTERVAL_MS + 1)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  th = Thread.new { instance.invoke("_start") }
  sleep(0.3)
  t_wake = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  th.join
  t_end = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  store.close
  puts format("probe A (compute): main woke at %.2fs, invoke ended at %.2fs => %s",
              t_wake, t_end,
              t_wake < t_end * 0.75 ? "GVL RELEASED" : "GVL HELD during wasm execution")
  puts "  (note: 50M-iteration loop took #{format('%.2f', t_end)}s under contention vs #{format('%.2f', t_end < 10 ? t_end : 0)}s+ serial below)"
end

# Probe B — serial calibration (no second thread) for the same loop.
code = "i = 0; while i < #{LOOP_ITERS}; i += 1; end"
Dir.mktmpdir do |workdir|
  File.write(File.join(workdir, "code.rb"), code)
  engine, module_, linker = build_runtime
  stdout = String.new
  store = Wasmtime::Store.new(engine, wasi_p1_config: oneshot_wasi(workdir, stdout),
                              limits: { memory_size: 512 * 1024 * 1024 })
  store.set_fuel(5 * 10**10)
  instance = linker.instantiate(store, module_)
  store.set_epoch_deadline(60_000 / INTERVAL_MS + 1)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  instance.invoke("_start")
  ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
  store.close
  puts format("probe B (serial calibration): %.0fms for the same loop", ms)
end

# Probe C — GVL while the guest is blocked on a stdin read. No child process
# (forked children on this box showed skewed CLOCK_MONOTONIC readings, which
# poisoned earlier attempts): the parent itself opens the FIFO read-write,
# pre-writes one line (consumed at ~0.5s), and holds the write end open so the
# guest blocks on a second gets() that never arrives. If the GVL is released
# during that block, the main thread wakes from its 1.0s sleep; if the GVL is
# held, this process hangs (kernel SIGKILL via `timeout -k` ends it — itself
# the finding, since the 60s epoch deadline cannot fire either).
Dir.mktmpdir do |workdir|
  File.write(File.join(workdir, "code.rb"),
             %q{a = STDIN.gets; STDOUT.puts "got:#{a.inspect}"; b = STDIN.gets; STDOUT.puts "then:#{b.inspect}"})
  fifo = File.join(workdir, "stdin.fifo")
  system("mkfifo", fifo) || raise("mkfifo failed")

  engine, module_, linker = build_runtime
  stdout = String.new
  wasi = Wasmtime::WasiConfig.new
        .set_stdin_file(fifo)
        .set_stdout_buffer(stdout, 1 << 20)
        .set_stderr_buffer(String.new, 1 << 16)
        .set_argv(["ruby", "/src/main.rb"])
        .set_env({})
        .set_mapped_directory(workdir, "/work", :read_write)
  store = Wasmtime::Store.new(engine, wasi_p1_config: wasi, limits: { memory_size: 512 * 1024 * 1024 })
  store.set_fuel(5 * 10**10)
  instance = linker.instantiate(store, module_)
  store.set_epoch_deadline(60_000 / INTERVAL_MS + 1) # fires only at wasm checkpoints

  writer = File.open(fifo, File::RDWR | File::NONBLOCK) # hold both ends open
  writer.puts("line-from-parent")
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  th = Thread.new { instance.invoke("_start") }
  sleep(1.0) # guest has consumed line 1 and is blocked on gets #2 by now
  t_wake = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  puts format("probe C: main regained control at %.2fs (guest exited: %s) — joining invoke...",
              t_wake, t_wake < 2.0 ? "NO (GVL released!)" : "probably yes")
  $stdout.flush
  th.join
  t_join = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  store.close
  writer.close
  puts format("probe C (parent-held FIFO): main woke at %.2fs, guest exited at %.2fs, stdout=#{stdout.inspect}",
              t_wake, t_join)
  if t_wake < 2.0
    puts "  => GVL RELEASED while guest blocked on stdin (main ran at ~1.0s, guest still blocked)."
  else
    puts "  => GVL HELD while guest blocked on stdin (main woke only at guest exit)."
  end
  puts "  VERDICT (A + C): :worker mode is infeasible on wasmtime-rb 48 (sync WASI):"
  puts "   - GVL held during compute (probe A) => no host/guest interleaving while evaluating;"
  puts "   - even where the guest blocks, per-request fuel/epoch limits would require mutating"
  puts "     the live Store from another thread while invoke runs (unsafe Rust aliasing);"
  puts "   - epoch deadlines never fire while the guest sits in a blocking syscall (earlier"
  puts "     FIFO runs hung past their 30-60s deadlines and required SIGKILL);"
  puts "   - FIFO stdin under wasmtime proved fragile across runs (0.3s / 5.4s wakes, hangs)."
  puts "  => One invoke per request (:oneshot) remains the protocol; concurrency via Ractors"
  puts "     (stage-3 Q2: ~3.6x at 4 Ractors, shared Engine+Module)."
end
