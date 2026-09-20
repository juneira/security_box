#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 5 spike — answers Q1..Q6 from docs/plan/stages/stage_5.md (folder mounts)
# Usage: bundle exec ruby bin/spike_stage5_mounts.rb
require "bundler/setup"
require "wasmtime"
require "json"
require "tmpdir"
require "fileutils"

IMAGE_PATH = File.expand_path("../lib/security_box/assets/security_box.wasm", __dir__)
INTERVAL_MS = 25

$report = []

def log(q, msg)
  $report << "[#{q}] #{msg}"
  puts "[#{q}] #{msg}"
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
  @mod ||= Wasmtime::Module.from_file(engine, IMAGE_PATH)
end

# Runs `code` with the given mounts (array of [host, guest, mode]).
# Returns {status, stdout, value, error, stderr}.
def run(code, mounts: [], timeout_ms: 2_000)
  stdout = String.new
  stderr = String.new
  workdir = Dir.mktmpdir("sb-spike5")

  wasi = Wasmtime::WasiConfig.new
        .set_stdin_string("")
        .set_stdout_buffer(stdout, 1 << 20)
        .set_stderr_buffer(stderr, 1 << 16)
        .set_argv(["ruby", "/src/main.rb", code])
        .set_env({})
        .set_mapped_directory(workdir, "/work", :read_write)
  mounts.each { |host, guest, mode| wasi = wasi.set_mapped_directory(host, guest, mode) }

  status = :ok
  value = nil
  error = nil
  store = nil
  begin
    store = Wasmtime::Store.new(engine, wasi_p1_config: wasi, limits: { memory_size: 512 * 1024 * 1024 })
    store.set_fuel(10_000_000_000)
    instance = Wasmtime::Linker.new(engine).tap { |l| Wasmtime::WASI::P1.add_to_linker_sync(l) }
                                .instantiate(store, module!)
    store.set_epoch_deadline(timeout_ms / INTERVAL_MS + 1)
    instance.invoke("_start")
  rescue Wasmtime::Trap => e
    status = e.code == :interrupt ? :timeout : e.code
    stderr << "\n[trap] #{e.code}"
  rescue Wasmtime::Error => e
    status = :wasmtime_error
    stderr << "\n[error] #{e.class}: #{e.message[0, 200]}"
  ensure
    out_file = File.join(workdir, "out.json")
    if File.exist?(out_file)
      data = JSON.parse(File.read(out_file)) rescue nil
      value = data && data["value"]
      error = data && data["error"]
    end
    store&.close
    FileUtils.remove_entry(workdir) if File.directory?(workdir)
  end

  { status: status, stdout: stdout, value: value, error: error, stderr: stderr }
end

def report(q, r, label = nil)
  if r[:value]
    r[:value].each { |k, res| log(q, "#{label}#{k}: #{res.inspect}") }
  elsif r[:error]
    log(q, "#{label}guest error: #{r[:error].inspect}")
  else
    log(q, "#{label}NO ENVELOPE status=#{r[:status]} stdout=#{r[:stdout].inspect[0, 120]} stderr=#{r[:stderr].inspect[0, 160]}")
  end
end

# Guest-side probe helper: sent verbatim, so it must live in the guest snippet.
GUEST_PC = <<~RUBY
  def pc
    yield
  rescue Exception => ex
    "RESCUED \#{ex.class}: \#{ex.message}"
  end
RUBY

def p50(times)
  sorted = times.sort
  sorted[times.size / 2]
end

puts "== security_box stage 5 spike (folder mounts) =="
puts "ruby #{RUBY_VERSION} | image: #{IMAGE_PATH} (#{File.size(IMAGE_PATH) / 1024 / 1024}MB)"

# Host fixture: a data tree with a nested dir, and symlinks that escape it.
data_dir = Dir.mktmpdir("sb-data5")
File.write(File.join(data_dir, "hello.txt"), "hello from host\n")
File.write(File.join(data_dir, "secret.txt"), "s3cr3t\n")
FileUtils.mkdir(File.join(data_dir, "sub"))
File.write(File.join(data_dir, "sub", "nested.txt"), "nested\n")
File.symlink("/etc/hostname", File.join(data_dir, "link_abs"))
File.symlink("../../etc/hostname", File.join(data_dir, "link_rel"))
File.symlink("hello.txt", File.join(data_dir, "link_ok"))
host_listing = Dir.children(data_dir).sort

ro = [data_dir, "/data", :read_only]

# --- Q1: read-only mount — reads work, writes fail ---
r = run(<<~RUBY, mounts: [ro])
  #{GUEST_PC}
  {
    "read"   => File.read("/data/hello.txt"),
    "glob"   => Dir["/data/**/*"].sort,
    "open"   => File.open("/data/hello.txt", "r") { |f| f.read(5) },
    "nested" => File.read("/data/sub/nested.txt"),
    "File.write" => pc { File.write("/data/evil.txt", "x") },
    "open_w"     => pc { File.open("/data/evil.txt", "w") { |f| f.write("x") } },
    "append"     => pc { File.open("/data/hello.txt", "a") { |f| f.write("x") } },
    "mkdir"      => pc { Dir.mkdir("/data/newdir") },
    "unlink"     => pc { File.delete("/data/hello.txt") },
    "rename"     => pc { File.rename("/data/hello.txt", "/data/renamed.txt") },
    "chmod"      => pc { File.chmod(0o777, "/data/hello.txt") }
  }
RUBY
report("Q1", r)
host_clean = File.read(File.join(data_dir, "hello.txt")) == "hello from host\n" &&
             Dir.children(data_dir).sort == host_listing
log("Q1", "host dir unchanged after run: #{host_clean}")

# --- Q1b: symlink escape probes (read-only mount) ---
r = run(<<~RUBY, mounts: [ro])
  #{GUEST_PC}
  {
    "link_ok"  => pc { File.read("/data/link_ok") },
    "link_abs" => pc { File.read("/data/link_abs") },
    "link_rel" => pc { File.read("/data/link_rel") }
  }
RUBY
report("Q1b", r)

# --- Q1c: read-write mount round-trip ---
rw_dir = Dir.mktmpdir("sb-rw5")
File.write(File.join(rw_dir, "hello.txt"), "rw seed\n")
r = run(<<~RUBY, mounts: [[rw_dir, "/rw", :read_write]])
  #{GUEST_PC}
  {
    "read"  => File.read("/rw/hello.txt"),
    "write" => pc { File.write("/rw/made_by_guest.txt", "guest was here") },
    "reread" => pc { File.read("/rw/made_by_guest.txt") }
  }
RUBY
report("Q1c", r)
log("Q1c", "host sees guest-written file: #{File.read(File.join(rw_dir, 'made_by_guest.txt')) == 'guest was here' rescue false}")

# --- Q2: /work + embedded VFS coexistence with N mounts ---
more = (1..3).map do |i|
  d = Dir.mktmpdir("sb-m5")
  File.write(File.join(d, "f#{i}.txt"), "m#{i}")
  [d, "/mnt#{i}", :read_only]
end
r = run(<<~RUBY, mounts: [ro, *more])
  #{GUEST_PC}
  {
    "stdlib"  => pc { require "json"; JSON.generate({ "a" => 1 }) },
    "entry"   => pc { File.exist?("/src/main.rb") },
    "work_rw" => pc { File.write("/work/x.txt", "1") },
    "mounts"  => [File.read("/data/hello.txt"), File.read("/mnt1/f1.txt"), File.read("/mnt2/f2.txt"), File.read("/mnt3/f3.txt")],
    "root"    => Dir["/*"].sort
  }
RUBY
report("Q2", r)

# --- Q2b: shadowing — what wins when a mount collides with an embedded path?
shadow_dir = Dir.mktmpdir("sb-shadow5")
File.write(File.join(shadow_dir, "SHADOW_MARKER"), "mounted-content")
r = run(<<~RUBY, mounts: [[shadow_dir, "/usr", :read_only]])
  #{GUEST_PC}
  {
    "marker" => pc { File.read("/usr/SHADOW_MARKER") },
    "stdlib" => pc { require "json"; JSON.generate({ "a" => 1 }) },
    "root"   => Dir["/*"].sort
  }
RUBY
report("Q2b", r, "shadow /usr ")
r = run(<<~RUBY, mounts: [[shadow_dir, "/src", :read_only]])
  #{GUEST_PC}
  {
    "marker" => pc { File.read("/src/SHADOW_MARKER") },
    "main"   => pc { File.read("/src/main.rb")[0, 40] }
  }
RUBY
report("Q2b", r, "shadow /src ")

# --- Q2c: two mounts at the same guest path ---
d1 = Dir.mktmpdir("sb-dup1"); File.write(File.join(d1, "who.txt"), "first\n")
d2 = Dir.mktmpdir("sb-dup2"); File.write(File.join(d2, "who.txt"), "second\n")
r = run('begin; File.read("/dup/who.txt"); rescue Exception => ex; "RESCUED #{ex.class}: #{ex.message}"; end',
        mounts: [[d1, "/dup", :read_only], [d2, "/dup", :read_only]])
log("Q2c", "same guest path twice: #{r[:value].inspect}")

# --- Q3: host-side failure modes ---
r = run("1", mounts: [["/nonexistent_#{Process.pid}_sb", "/data", :read_only]])
log("Q3", "nonexistent host dir: status=#{r[:status]} stderr=#{r[:stderr].inspect[0, 160]}")
r = run("1", mounts: [[File.join(data_dir, "hello.txt"), "/data", :read_only]])
log("Q3", "host path is a file: status=#{r[:status]} value=#{r[:value].inspect} stderr=#{r[:stderr].inspect[0, 160]}")

# --- Q6: can guest code tamper with the embedded VFS? ---
r = run(<<~RUBY)
  #{GUEST_PC}
  {
    "write_usr"  => pc { File.write("/usr/sbpwned.txt", "x") },
    "write_src"  => pc { File.write("/src/sbpwned.rb", "x") },
    "delete_usr" => pc { File.delete("/usr/local/bin/ruby") },
    "write_root" => pc { File.write("/sbpwned.txt", "x") },
    "mkdir_root" => pc { Dir.mkdir("/sbdir") }
  }
RUBY
report("Q6", r)

# --- Q4: warm-boot latency with 0/1/4/8 mounts ---
dirs = (1..8).map do |i|
  d = Dir.mktmpdir("sb-lat5")
  File.write(File.join(d, "f.txt"), "x")
  d
end
{ 0 => [],
  1 => [[dirs[0], "/m1", :read_only]],
  4 => dirs.first(4).each_with_index.map { |d, i| [d, "/m#{i + 1}", :read_only] },
  8 => dirs.each_with_index.map { |d, i| [d, "/m#{i + 1}", :read_only] } }.each do |n, ms|
  times = 5.times.map do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run("File.read('/m1/f.txt') if #{n} > 0", mounts: ms)
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
  end
  log("Q4", "#{n} mount(s): p50=#{p50(times).round(1)}ms all=#{times.map { |t| t.round(0) }.join(',')}")
end

puts "\n== summary =="
$report.each { |line| puts line }
