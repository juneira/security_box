#!/usr/bin/env ruby
# frozen_string_literal: true

# Stage 5 spike addendum — reserved-path overlap + symlink cross-preopen writes
require "bundler/setup"
require "wasmtime"
require "json"
require "tmpdir"
require "fileutils"

IMAGE = File.expand_path("../lib/security_box/assets/security_box.wasm", __dir__)
engine = Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true)
engine.start_epoch_interval(25)
mod = Wasmtime::Module.from_file(engine, IMAGE)

def run(engine, mod, code, mounts)
  stdout = String.new
  stderr = String.new
  workdir = Dir.mktmpdir("sb-p")
  wasi = Wasmtime::WasiConfig.new.set_stdin_string("")
        .set_stdout_buffer(stdout, 1 << 20).set_stderr_buffer(stderr, 1 << 16)
        .set_argv(["ruby", "/src/main.rb", code]).set_env({})
        .set_mapped_directory(workdir, "/work", :read_write)
  mounts.each { |h, g, m| wasi = wasi.set_mapped_directory(h, g, m) }
  store = Wasmtime::Store.new(engine, wasi_p1_config: wasi, limits: { memory_size: 512 * 1024 * 1024 })
  out = nil
  begin
    store.set_fuel(10_000_000_000)
    inst = Wasmtime::Linker.new(engine).tap { |l| Wasmtime::WASI::P1.add_to_linker_sync(l) }.instantiate(store, mod)
    store.set_epoch_deadline(81)
    inst.invoke("_start")
  rescue Wasmtime::WasiExit => e
    out = "GUEST-EXITED code=#{e.code}"
  rescue Wasmtime::Trap => e
    out = "TRAP #{e.code}"
  ensure
    out ||= File.exist?(File.join(workdir, "out.json")) ? (JSON.parse(File.read(File.join(workdir, "out.json")))["value"] rescue nil) : nil
  end
  store&.close
  FileUtils.remove_entry(workdir)
  out || "NO ENVELOPE stdout=#{stdout[0, 80].inspect} stderr=#{stderr[0, 120].inspect}"
end

data = Dir.mktmpdir("sb-data")
File.write(File.join(data, "f.txt"), "x")

# Nested reserved guest paths
puts "mount at /usr/local (read)  -> #{run(engine, mod, %q{begin; File.read('/usr/local/f.txt'); rescue Exception => ex; "RESCUED #{ex.class}: #{ex.message}"; end}, [[data, "/usr/local", :read_only]]).inspect}"
puts "mount at /work/sub (read)   -> #{run(engine, mod, %q{begin; File.read('/work/sub/f.txt'); rescue Exception => ex; "RESCUED #{ex.class}: #{ex.message}"; end}, [[data, "/work/sub", :read_only]]).inspect}"
puts "mount at /work/sub (write)  -> #{run(engine, mod, %q{begin; File.write('/work/sub/g.txt', 'w'); rescue Exception => ex; "RESCUED #{ex.class}: #{ex.message}"; end}, [[data, "/work/sub", :read_only]]).inspect}"

# Symlink from writable /work into the RO mount, then write through it
code = <<~RUBY
  r = []
  begin
    File.symlink("/data/f.txt", "/work/l_in")
    r << (File.read("/work/l_in") rescue "READ-RESCUED #{$!.class}")
    begin
      File.write("/work/l_in", "x")
      r << "WRITE-OK(!)"
    rescue Exception => ex
      r << "WRITE-RESCUED \#{ex.class}: \#{ex.message}"
    end
    File.symlink("/etc/hostname", "/work/l_out")
    r << (File.read("/work/l_out") rescue "READ-OUT-RESCUED \#{$!.class}")
  rescue Exception => ex
    r << "RESCUED \#{ex.class}: \#{ex.message}"
  end
  r
RUBY
puts "symlinks via /work: #{run(engine, mod, code, [[data, "/data", :read_only]]).inspect}"
