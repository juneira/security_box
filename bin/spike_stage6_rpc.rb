# frozen_string_literal: true

# Stage-6 spike: blocking host RPC from inside the sandbox ("code mode").
#
# Validates, with evidence, the design where guest Ruby calls
# `SBExt.call` (a wasm import provided by the host through
# Wasmtime::Linker#func_new) and blocks while the host executes the
# handler:
#
#   Q1 image build: rbwasm build compiles the sb_rpc C extension
#       (import sb/call) statically into the image and rbwasm pack adds
#       /src and the gem VFS.
#   Q2 require: the guest can load the statically linked extension via
#       /bundle/setup.rb + require "sb_rpc".
#   Q3 round-trip: guest -> import -> host handler -> guest value.
#   Q4 blocking: the guest observes wall-clock time passing inside
#       Sb.call and continues afterwards (linear code, no callbacks).
#   Q5 handler errors: a raising handler becomes a guest-rescuable
#       error (no host exception escapes through the wasm boundary).
#   Q6 unknown rpc name: guest-rescuable error, no host crash.
#   Q7 transcript: per-eval calls are visible host-side via store_data.
#   Q8 wall-clock semantics: a slow handler is not interrupted by the
#       epoch deadline while the guest is suspended; if the deadline
#       passes during the host call, the guest traps on the next epoch
#       check (documented: timeout_ms covers guest compute + RPC time).
#
# Requires: lib/security_box/guest_ext/*, the ruby.wasm toolchain
# downloads on first build (ruby source + wasi-sdk + binaryen into
# build/), and the prebuilt image flow (build/ artifacts are not
# committed).
#
# Usage: bundle exec ruby bin/spike_stage6_rpc.rb [--skip-build]
require "bundler/setup"
require "wasmtime"
require "json"
require "securerandom"
require "tmpdir"

PROJECT = File.expand_path("..", __dir__)
GUEST_DIR = File.join(PROJECT, "lib/security_box/guest")
GUEST_EXT_GEMFILE = File.join(PROJECT, "lib/security_box/guest_ext/Gemfile")
BASE_IMAGE = File.join(PROJECT, "build/spike_rpc_base.wasm")
SPIKE_IMAGE = File.join(PROJECT, "build/spike_rpc.wasm")
SKIP_BUILD = ARGV.delete("--skip-build")
EPOCH_INTERVAL_MS = 25

# --- image build (Q1) --------------------------------------------------------

def guest_fresh?(image)
  image && File.exist?(image) &&
    File.mtime(image) >= Dir[File.join(GUEST_DIR, "*.rb")]
      .map { |f| File.mtime(f) }.max
end

unless SKIP_BUILD || guest_fresh?(SPIKE_IMAGE)
  puts "== building image (first build downloads ruby source + wasi-sdk + binaryen)"
  # Build subprocesses must run under the guest_ext bundle (sb_rpc native
  # gem) while the spike itself runs under the host bundle (wasmtime).
  # with_unbundled_env strips the parent's bundler injection (RUBYOPT,
  # BUNDLE_*); the guest vars are then set explicitly.
  build = lambda do |command|
    Bundler.with_unbundled_env do
      ENV["RUBY_WASM_ROOT"] = PROJECT
      # Running from the guest_ext directory makes bundler resolve its
      # local Gemfile without BUNDLE_GEMFILE (which, inherited by other
      # bundler invocations, can rewrite the wrong lockfile).
      result = system(command, chdir: File.dirname(GUEST_EXT_GEMFILE), exception: true)
      ENV.delete("RUBY_WASM_ROOT")
      result
    end
  end
  build.call("bundle lock") unless File.exist?(File.join(File.dirname(GUEST_EXT_GEMFILE), "Gemfile.lock"))
  build.call("bundle exec rbwasm build --ruby-version 4.0 " \
             "--target wasm32-unknown-wasip1 --build-profile full " \
             "-o #{BASE_IMAGE}") || exit(1)
  system("bundle exec rbwasm pack #{BASE_IMAGE} " \
         "--dir #{GUEST_DIR}::/src -o #{SPIKE_IMAGE}", exception: true) || exit(1)
end
abort "spike image missing at #{SPIKE_IMAGE} (run without --skip-build)" unless File.exist?(SPIKE_IMAGE)
puts "image: #{SPIKE_IMAGE} (#{File.size(SPIKE_IMAGE) / 1024 / 1024}MB)"

# --- runtime + RPC import wiring ---------------------------------------------

ENGINE = Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true)
MODULE = Wasmtime::Module.from_file(ENGINE, SPIKE_IMAGE)
LINKER = Wasmtime::Linker.new(ENGINE)
Wasmtime::WASI::P1.add_to_linker_sync(LINKER)

# Epoch timer (mirrors Runtime.build_engine). The native engine timer is
# required: a Ruby timer thread cannot run while invoke holds the GVL
# (stage-4 Q1), so epoch deadlines would never fire during guest compute.
ENGINE.start_epoch_interval(EPOCH_INTERVAL_MS)

# Host-side RPC entrypoint ("sb" "call"). Per-eval state (workdir,
# handlers, transcript) arrives via caller.store_data — the closure
# itself is generic and safe to reuse across evaluations. A raising
# handler must never escape through the wasm boundary: it is encoded as
# an error response the guest can rescue (Q5).
LINKER.func_new("sb", "call", [], [:i32]) do |caller|
  data = caller.store_data
  workdir = data[:workdir]
  request = JSON.parse(File.read(File.join(workdir, "rpc_req.json")))
  data[:calls] << { "name" => request["name"], "args" => request["args"] }

  handler = data[:handlers][request["name"]]
  if handler.nil?
    File.write(File.join(workdir, "rpc_resp.json"),
               JSON.generate({ "ok" => false,
                               "error" => { "class" => "SB::UnknownTool",
                                            "message" => "unknown rpc: #{request["name"]}" } }))
    next 0
  end

  result = handler.call(request["args"])
  File.write(File.join(workdir, "rpc_resp.json"),
             JSON.generate({ "ok" => true, "result" => result }))
  0
rescue StandardError => e
  data[:calls] << { "name" => "error", "args" => e.class.name } if data[:calls]
  begin
    File.write(File.join(data[:workdir], "rpc_resp.json"),
               JSON.generate({ "ok" => false,
                               "error" => { "class" => e.class.name,
                                            "message" => e.message.to_s } }))
  rescue StandardError
    nil
  end
  0
end

# Minimal eval core (mirrors EvalRun) with the RPC import wired.
def rpc_eval(code, handlers, timeout_ms: 2_000, fuel: 20_000_000_000)
  calls = []
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Dir.mktmpdir("spike_rpc") do |workdir|
    File.write(File.join(workdir, "code.rb"), code)
    stdout = +""
    stderr = +""
    token = SecureRandom.hex(16)
    wasi = Wasmtime::WasiConfig.new
             .set_stdin_string("")
             .set_stdout_buffer(stdout, 1 << 20)
             .set_stderr_buffer(stderr, 1 << 16)
             .set_argv(["ruby", "/src/main.rb"])
             .set_env({ "SB_TOKEN" => token })
             .set_mapped_directory(workdir, "/work", :read_write)
    store = Wasmtime::Store.new(
      ENGINE, { workdir: workdir, handlers: handlers, calls: calls },
      wasi_p1_config: wasi
    )
    store.set_fuel(fuel)
    instance = LINKER.instantiate(store, MODULE)
    store.set_epoch_deadline(timeout_ms / EPOCH_INTERVAL_MS + 1)
    status = begin
      instance.invoke("_start")
      :ok
    rescue Wasmtime::WasiExit
      :sandbox_error
    rescue Wasmtime::Trap => e
      e.code == :interrupt ? :timeout : e.code
    end
    envelope = begin
      JSON.parse(File.read(File.join(workdir, "out.json")))
    rescue SystemCallError, JSON::ParserError
      nil
    end
    {
      status: status, envelope: envelope, stdout: stdout, stderr: stderr,
      calls: calls, fuel_used: fuel - store.get_fuel,
      duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    }
  end
end

def value(result)
  result[:envelope] && result[:envelope]["ok"] ? result[:envelope]["value"] : nil
end

def report(name, ok, detail)
  puts(format("%-8s %-24s %s", ok ? "PASS" : "FAIL", name, detail))
  ok
end

results = []
HANDLERS = {
  "double" => ->(args) { args["n"].to_i * 2 },
  "slow" => ->(args) { sleep(args["ms"].to_i / 1000.0); "slept-#{args["ms"]}" },
  "boom" => ->(_args) { raise RuntimeError, "boom" }
}.freeze

# --- Q2/Q3: require + round-trip ---------------------------------------------
r = rpc_eval(<<~CODE, HANDLERS)
  require "/bundle/setup.rb"
  require "sb_rpc"
  require "json"

  def sb_call(name, args = {})
    File.write("/work/rpc_req.json", JSON.generate({ name: name, args: args }))
    status = SBExt.call
    raise "rpc transport failed (\#{status})" unless status.zero?

    resp = JSON.parse(File.read("/work/rpc_resp.json"))
    raise resp.dig("error", "message").to_s unless resp["ok"]

    resp["result"]
  end

  sb_call("double", n: 21) + 1
CODE
results << report("Q2 require sb_rpc", !r[:stderr].to_s.include?("LoadError"),
                  "stderr: #{r[:stderr].to_s[0, 120].inspect}")
results << report("Q3 round-trip", r[:status] == :ok && value(r) == 43,
                  "status=#{r[:status]} value=#{value(r).inspect} fuel=#{r[:fuel_used]}")

# --- Q4: blocking semantics ---------------------------------------------------
r = rpc_eval(<<~CODE, HANDLERS)
  require "/bundle/setup.rb"
  require "sb_rpc"
  require "json"

  def sb_call(name, args = {})
    File.write("/work/rpc_req.json", JSON.generate({ name: name, args: args }))
    status = SBExt.call
    raise "rpc transport failed (\#{status})" unless status.zero?

    resp = JSON.parse(File.read("/work/rpc_resp.json"))
    raise resp.dig("error", "message").to_s unless resp["ok"]

    resp["result"]
  end

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  x = sb_call("slow", ms: 400)
  dt = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
  [x == "slept-400", dt]
CODE
blocked = value(r).is_a?(Array) && value(r)[0] == true && value(r)[1].to_i >= 400
results << report("Q4 blocking call", r[:status] == :ok && blocked,
                  "status=#{r[:status]} value=#{value(r).inspect}")

# --- Q5: handler errors are guest-rescuable -----------------------------------
r = rpc_eval(<<~CODE, HANDLERS)
  require "/bundle/setup.rb"
  require "sb_rpc"
  require "json"

  def sb_call(name, args = {})
    File.write("/work/rpc_req.json", JSON.generate({ name: name, args: args }))
    status = SBExt.call
    raise "rpc transport failed (\#{status})" unless status.zero?

    resp = JSON.parse(File.read("/work/rpc_resp.json"))
    raise resp.dig("error", "message").to_s unless resp["ok"]

    resp["result"]
  end

  begin
    sb_call("boom")
    "no-raise"
  rescue StandardError => e
    "\#{e.class}: \#{e.message}"
  end
CODE
results << report("Q5 handler error", value(r) == "RuntimeError: boom",
                  "status=#{r[:status]} value=#{value(r).inspect}")

# --- Q6: unknown rpc name ------------------------------------------------------
r = rpc_eval(<<~CODE, HANDLERS)
  require "/bundle/setup.rb"
  require "sb_rpc"
  require "json"

  def sb_call(name, args = {})
    File.write("/work/rpc_req.json", JSON.generate({ name: name, args: args }))
    status = SBExt.call
    raise "rpc transport failed (\#{status})" unless status.zero?

    resp = JSON.parse(File.read("/work/rpc_resp.json"))
    raise resp.dig("error", "message").to_s unless resp["ok"]

    resp["result"]
  end

  begin
    sb_call("missing_tool")
    "no-raise"
  rescue StandardError => e
    "\#{e.class}: \#{e.message}"
  end
CODE
results << report("Q6 unknown rpc", value(r) == "RuntimeError: unknown rpc: missing_tool",
                  "status=#{r[:status]} value=#{value(r).inspect}")

# --- Q7: transcript ------------------------------------------------------------
r = rpc_eval(<<~CODE, HANDLERS)
  require "/bundle/setup.rb"
  require "sb_rpc"
  require "json"

  def sb_call(name, args = {})
    File.write("/work/rpc_req.json", JSON.generate({ name: name, args: args }))
    status = SBExt.call
    raise "rpc transport failed (\#{status})" unless status.zero?

    resp = JSON.parse(File.read("/work/rpc_resp.json"))
    raise resp.dig("error", "message").to_s unless resp["ok"]

    resp["result"]
  end

  [sb_call("double", n: 1), sb_call("double", n: 2)].sum
CODE
names = r[:calls].map { |c| c["name"] }
results << report("Q7 transcript", value(r) == 6 && names == %w[double double],
                  "value=#{value(r).inspect} calls=#{names.inspect}")

# --- Q8: wall-clock semantics with a slow handler --------------------------------
# Note: with a working epoch timer, timeout_ms covers the whole eval
# (boot + guest compute + host call time); the guest traps at the first
# epoch check after the deadline passes.
r_slow = rpc_eval(<<~CODE, HANDLERS, timeout_ms: 1_500)
  require "/bundle/setup.rb"
  require "sb_rpc"
  require "json"

  def sb_call(name, args = {})
    File.write("/work/rpc_req.json", JSON.generate({ name: name, args: args }))
    status = SBExt.call
    raise "rpc transport failed (\#{status})" unless status.zero?

    resp = JSON.parse(File.read("/work/rpc_resp.json"))
    raise resp.dig("error", "message").to_s unless resp["ok"]

    resp["result"]
  end

  sb_call("slow", ms: 400)
CODE
results << report("Q8a slow handler completes",
                  r_slow[:status] == :ok && value(r_slow) == "slept-400",
                  "status=#{r_slow[:status]} value=#{value(r_slow).inspect} " \
                  "duration=#{r_slow[:duration_ms]}ms (deadline 1500ms)")

r_loop = rpc_eval(<<~CODE, HANDLERS, timeout_ms: 500, fuel: 200_000_000_000)
  require "/bundle/setup.rb"
  require "sb_rpc"
  require "json"

  def sb_call(name, args = {})
    File.write("/work/rpc_req.json", JSON.generate({ name: name, args: args }))
    status = SBExt.call
    raise "rpc transport failed (\#{status})" unless status.zero?

    resp = JSON.parse(File.read("/work/rpc_resp.json"))
    raise resp.dig("error", "message").to_s unless resp["ok"]

    resp["result"]
  end

  sb_call("slow", ms: 400)
  i = 0
  while i < 500_000_000
    i += 1
  end
  i
CODE
results << report("Q8b deadline trips on resume", r_loop[:status] == :timeout,
                  "status=#{r_loop[:status]} duration=#{r_loop[:duration_ms]}ms")

puts
ok = results.all?
puts "== spike #{ok ? "PASSED" : "FAILED"} (#{results.count(true)}/#{results.size})"
exit(ok ? 0 : 1)
