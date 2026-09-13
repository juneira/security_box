#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 1 spike — answers Q1..Q9 from docs/plan/stages/stage_1.md
# Usage: bundle exec ruby bin/spike.rb
require "bundler/setup"
require "wasmtime"
require "json"
require "tmpdir"

IMAGE_PATH = File.expand_path("../build/security_box.wasm", __dir__)
INTERVAL_MS = 25

$times = Hash.new { |h, k| h[k] = [] }
$report = []

def timed(label)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  $times[label] << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000)
  [result, $times[label].last]
end

def rss_mb
  File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i / 1024.0
end

def engine
  @engine ||= begin
    e = Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true)
    if e.respond_to?(:start_epoch_interval)
      e.start_epoch_interval(INTERVAL_MS)
    else
      Thread.new { loop { sleep(INTERVAL_MS / 1000.0); e.increment_epoch } }
    end
    e
  end
end

def module!
  @mod ||= timed("module_compile") { Wasmtime::Module.from_file(engine, IMAGE_PATH) }.first
end

# Runs `code` in a fresh sandbox. Returns a hash with status, stdout, out (JSON), fuel and timings.
def run(code, fuel: 10_000_000_000, timeout_ms: 2_000, memory_size: nil, use_work_dir: true)
  stdout = String.new
  stderr = String.new
  workdir = use_work_dir ? Dir.mktmpdir("sb-spike") : nil
  mem0 = rss_mb
  debug = ENV["SPIKE_DEBUG"]

  wasi = Wasmtime::WasiConfig.new
        .set_stdin_string("")
        .set_stdout_buffer(stdout, 1 << 20)
        .set_stderr_buffer(stderr, 1 << 16)
        .set_argv(["ruby", "/src/main.rb", code])
        .set_env({})
  wasi = wasi.set_mapped_directory(workdir, "/work", :read_write) if workdir

  limits = { memory_size: memory_size || 512 * 1024 * 1024 }
  _, store_ms = timed("store_new") { @store = Wasmtime::Store.new(engine, wasi_p1_config: wasi, limits: limits) }
  @store.set_fuel(fuel)

  begin
    _, inst_ms = timed("instantiate") { @instance = Wasmtime::Linker.new(engine).tap { |l| Wasmtime::WASI::P1.add_to_linker_sync(l) }.instantiate(@store, module!) }
  ensure
    link_ms = $times["instantiate"].last
  end

  status = :ok
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  @store.set_epoch_deadline(timeout_ms / INTERVAL_MS + 1)
  begin
    timed("invoke") { @instance.invoke("_start") }
  rescue Wasmtime::Trap => e
    status = trap_status(e)
    stderr << "\n[trap] #{e.class}: #{e.message} code=#{e.code.inspect}"
  rescue Wasmtime::Error => e
    status = :failed
    stderr << "\n[error] #{e.class}: #{e.message}"
  ensure
    invoke_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
    fuel_used = fuel - @store.get_fuel
    mem_hit = @store.linear_memory_limit_hit?
    out = parse_result(stdout, workdir)
    @store.close
    File.unlink(File.join(workdir, "out.json")) rescue nil
    File.unlink(File.join(workdir, "code.rb")) rescue nil
    Dir.rmdir(workdir) rescue nil
  end

  {
    status: status, stdout: stdout, stderr: stderr, out: out,
    fuel_used: fuel_used, invoke_ms: invoke_ms.round(2), mem_hit: mem_hit,
    store_ms: store_ms.round(2), inst_ms: (link_ms || inst_ms).round(2),
    rss_delta_mb: (rss_mb - mem0).round(1)
  }.tap { |r| puts "DEBUG run: #{r.select { |k, _| %i[status stdout stderr].include?(k) }.inspect[0, 300]} workdir=#{workdir}" if debug }
end

def trap_status(trap)
  case trap.code
  when :interrupt then :timeout
  when :out_of_fuel then :fuel_exhausted
  when :memory_out_of_bounds then :memory_limit
  else :"trap_#{trap.code}"
  end
end

def parse_result(stdout, workdir)
  if workdir && File.exist?(f = File.join(workdir, "out.json"))
    { source: "/work/out.json", data: JSON.parse(File.read(f)) }
  elsif (line = stdout.lines.reverse.find { |l| l.start_with?("__SECURITY_BOX_RESULT__:") })
    { source: "stdout_sentinel", data: JSON.parse(line.sub("__SECURITY_BOX_RESULT__:", "")) }
  end
end

def log(q, msg)
  $report << "[#{q}] #{msg}"
  puts "[#{q}] #{msg}"
end

puts "== security_box stage 1 spike =="
puts "ruby #{RUBY_VERSION} | image: #{IMAGE_PATH} (#{File.size(IMAGE_PATH) / 1024 / 1024}MB)"

# Q1/Q2: basic execution + stdout capture (via /work)
r = run("puts 'hello from wasm'; 40 + 2")
log("Q1", "basic exec: status=#{r[:status]} stdout=#{r[:stdout].inspect} value=#{r[:out]&.dig(:source) ? r[:out][:data]['value'] : r[:out]&.data&.dig('value')} out_via=#{r[:out][:source]} invoke=#{r[:invoke_ms]}ms")

# Q3/Q4: sentinel fallback (no /work)
r2 = run("puts 'no workdir'; 7 * 6", use_work_dir: false)
log("Q3", "without /work: status=#{r2[:status]} out_via=#{r2[:out][:source]} value=#{r2[:out][:data]['value']}")

# Q5a: epoch — infinite loop
r3 = run("while true; end", timeout_ms: 500)
log("Q5", "infinite loop (epoch 500ms): status=#{r3[:status]} invoke=#{r3[:invoke_ms]}ms fuel_used=#{r3[:fuel_used]}")

# Q5b: fuel — calibrate fuel/second consumption
budget = 20_000_000_000
r4 = run("while true; end", fuel: budget, timeout_ms: 3_000)
rate = r4[:fuel_used] / (r4[:invoke_ms] / 1000.0)
log("Q5", "infinite loop (fuel): status=#{r4[:status]} fuel_used=#{r4[:fuel_used]} (#{rate.round} fuel/s) invoke=#{r4[:invoke_ms]}ms")

# Q6: spawn cost (module already compiled) — 5 "hello" spawns
rss_start = rss_mb
spawn_times = 5.times.map do
  x = run("1")
  print "rss=#{rss_mb.round}MB "
  x[:store_ms] + x[:inst_ms] + x[:invoke_ms]
end
puts
log("Q6", "total spawn (store+inst+invoke) 5x: #{spawn_times.map { |t| t.round(1) }.join(', ')} ms | rss start=#{rss_start.round}MB end=#{rss_mb.round}MB")
log("Q6", "module compiled once: #{$times['module_compile'].first.round(1)}ms (Module cache reused afterwards)")

# Q7: isolation
probes = {
  "File.write /etc/passwd" => "File.write('/etc/passwd', 'pwned')",
  "Dir['/']"               => "p Dir['/*'].size",
  "system('ls')"           => "p system('ls')",
  "backtick"               => "p `ls`",
  "fork"                   => "p fork",
  "require socket"         => "require 'socket'; p TCPServer",
  "ENV"                    => "p ENV.to_h.size",
  "Thread.new"             => "p Thread.new { 1 }",
  "IO.popen"               => "p IO.popen('ls')",
}
probes.each do |name, snippet|
  guest_code = "begin; #{snippet}; rescue => ex; puts \"rescued: \#{ex.class}\"; end"
  r7 = run(guest_code, timeout_ms: 1000)
  v = r7[:out] && r7[:out][:data]
  log("Q7", "#{name}: stdout=#{r7[:stdout].inspect} out=#{v && v['value'].inspect} err=#{v && v['error'].inspect} status=#{r7[:status]}")
end

# Q8: memory limit
r8 = run("a = []; loop { a << ('x' * 1024) }", memory_size: 128 * 1024 * 1024, timeout_ms: 5_000)
log("Q8", "memory_size=128MB + infinite allocation: status=#{r8[:status]} mem_hit=#{r8[:mem_hit]} stderr=#{r8[:stderr].inspect[0, 160]}")

# Q9: concurrency — 4 threads with infinite loops (500ms each); total wall should be ~500ms, not ~2000ms
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
threads = 4.times.map do
  Thread.new do
    run("while true; end", timeout_ms: 500)
  end
end
results9 = threads.map(&:value)
wall9 = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
log("Q9", "4 parallel infinite loops: wall=#{wall9.round}ms (expected ~500-600ms if GVL is released) status=#{results9.map { |x| x[:status] }.join(',')}")

# Q9b: 4 threads x fast boot (no loop) — separates boot serialization from wasm serialization
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
threads = 4.times.map { Thread.new { run("1") } }
results9b = threads.map(&:value)
wall9b = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
serial_ms = results9b.sum { |x| x[:invoke_ms] }
log("Q9b", "4 parallel boots: wall=#{wall9b.round}ms vs serial sum=#{serial_ms.round}ms (ratio=#{(wall9b / serial_ms).round(2)})")

puts "\n== medians (ms) =="
$times.each do |k, v|
  next if k == "module_compile"
  sorted = v.sort
  puts format("%-14s p50=%.2f  min=%.2f  max=%.2f  n=%d", k, sorted[v.size / 2], sorted.first, sorted.last, v.size)
end
