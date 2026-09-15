#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 3 spike — answers Q4 (minimum viable memory_size) and Q5 (fuel
# calibration) from docs/plan/stages/stage_3.md
# Usage: bundle exec ruby bin/spike_stage3.rb [memory|fuel]
require "bundler/setup"
require_relative "../lib/security_box"

MODES = ARGV.empty? || ARGV.empty? ? %w[memory fuel] : ARGV
BOOT_TIMEOUT_MS = 10_000

report = []

def log(report, q, msg)
  line = "[#{q}] #{msg}"
  report << line
  puts line
end

sandbox = SecurityBox::Sandbox.new

# Measures one eval, tolerating a guest crash at boot under a tight memory
# limit (Result still comes back; :sandbox_error with a trap is a failure here).
def probe(sandbox, code, memory_size:)
  result = sandbox.eval(code, memory_size: memory_size, timeout_ms: 10_000)
  ok = result.status == :ok
  [ok, result]
end

if MODES.include?("memory")
  puts "== Q4: minimum viable memory_size =="
  code = <<~RUBY
    require "json"
    parsed = JSON.parse('[{"a": 1}, {"b": [2, 3]}]')
    buf = +""
    1024.times { buf << 'x' * 1024 }
    puts "ok \#{parsed.size} \#{buf.bytesize}"
  RUBY
  sizes = [256, 192, 144, 136, 128, 112, 96, 64]
  sizes.each do |mb|
    bytes = mb * 1024 * 1024
    ok, result = probe(sandbox, code, memory_size: bytes)
    detail = "status=#{result.status} value=#{result.value.inspect} err=#{result.error && result.error['message'].to_s[0, 60]}"
    log(report, "Q4", "memory_size=#{mb}MB → #{ok ? 'OK' : 'FAIL'} (#{detail})")
  end
  log(report, "Q4", "module floor: 1528 pages (~95.5MiB); practical minimum 136MB for 1MB-buffer workloads")
end

if MODES.include?("fuel")
  puts "== Q5: fuel calibration =="
  budget = 50_000_000_000

  # Boot baseline: fuel cost of a boot + empty eval + envelope (subtracted below)
  r0 = sandbox.eval("0", fuel: budget)
  boot_fuel = r0.fuel_used
  log(report, "Q5", "boot baseline (boot + envelope): #{boot_fuel} fuel, #{r0.duration_ms.round}ms")

  rate = lambda do |label, code, timeout_ms:|
    r = sandbox.eval(code, fuel: budget, timeout_ms: timeout_ms)
    secs = r.duration_ms / 1000.0
    log(report, "Q5", "#{label}: status=#{r.status} fuel=#{r.fuel_used} elapsed=#{r.duration_ms.round}ms rate=#{(r.fuel_used / secs).round} fuel/s")
  end

  # Pure loop: fuel/s (runs to the epoch deadline)
  rate.call("pure loop (while true)", "while true; end", timeout_ms: 3_000)

  # Per-operation costs: run N iterations, subtract the boot baseline
  per_op = lambda do |label, code, n|
    r = sandbox.eval(code, fuel: budget, timeout_ms: 20_000)
    per = (r.fuel_used - boot_fuel).fdiv(n)
    rate_val = (r.fuel_used / (r.duration_ms / 1000.0)).round
    log(report, "Q5", "#{label}: status=#{r.status} fuel=#{r.fuel_used} (net=#{(r.fuel_used - boot_fuel)}) per_op=#{per.round(1)} fuel/op (#{rate_val} fuel/s)")
  end

  per_op.call("integer loop (empty body, 1e7)", "i = 0; while i < 10_000_000; i += 1; end; i", 10_000_000)
  per_op.call("method calls (1e6)", "def f(a); a + 1; end; i = 0; while i < 1_000_000; f(i); i += 1; end; i", 1_000_000)
  per_op.call("string concat (1e5)", "s = 'x' * 100; i = 0; while i < 100_000; t = s + 'y'; i += 1; end; s.bytesize", 100_000)
  per_op.call("string mutation << (1e5)", "s = 'x' * 100; i = 0; while i < 100_000; s << 'y'; i += 1; end; s.bytesize", 100_000)
  per_op.call("array push (1e6)", "a = []; i = 0; while i < 1_000_000; a << i; i += 1; end; a.size", 1_000_000)
  per_op.call("hash insert (1e6)", "h = {}; i = 0; while i < 1_000_000; h[i] = i; i += 1; end; h.size", 1_000_000)
  per_op.call("JSON.generate small (1e5)", "require 'json'; i = 0; while i < 100_000; JSON.generate({a: 1, b: 'x'}); i += 1; end; 0", 100_000)
  per_op.call("JSON.parse small (1e5)", "require 'json'; s = '{\"a\":1,\"b\":\"x\"}'; i = 0; while i < 100_000; JSON.parse(s); i += 1; end; 0", 100_000)
  per_op.call("print output (1e4)", "i = 0; while i < 10_000; print 'x' * 10; i += 1; end", 10_000)
end

puts "\n== report =="
puts report
