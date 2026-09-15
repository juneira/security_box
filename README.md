# security_box

[![Gem Version](https://img.shields.io/gem/v/security_box)](https://rubygems.org/gems/security_box)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A secure sandbox to run untrusted Ruby code, built on top of
[ruby.wasm](https://github.com/ruby/ruby.wasm) and the
[wasmtime](https://github.com/bytecodealliance/wasmtime-rb) gem.

Guest code runs inside a WebAssembly module compiled to `wasm32-unknown-wasip1`, so it has
no access to the host filesystem, no network, no processes, no threads and no sockets.
The host controls CPU (fuel), wall-clock time (epoch interruption), memory and output size,
and always gets a structured `Result` back — even when the guest code raises, times out or
tries to escape.

## How it works

1. A `ruby.wasm` image is packed with the Ruby runtime + stdlib + a small guest
   entrypoint (`lib/security_box/guest/main.rb`) plus a hardening prelude
   (`lib/security_box/guest/prelude.rb`).
2. On every `#eval`, the host creates an exclusive tmpdir, writes the user code to it, and
   mounts it read-write as `/work` inside the sandbox. It also generates a per-eval
   random token and passes it to the guest via `SB_TOKEN`.
3. A fresh wasm instance boots; the prelude captures the token, scrubs `ENV` and
   neutralizes process-spawn APIs, then the guest evaluates the code and serializes a
   token-signed JSON envelope to `/work/out.json` (stdout sentinel fallback).
4. The host validates the envelope (schema + token — forged results are rejected),
   maps any wasmtime trap to a `Result` status, closes the store and discards the tmpdir.

One wasm process per `#eval` means zero residual state between executions.

## Requirements

- Ruby >= 4.0 (host)
- `wasmtime` gem (runtime) — the only runtime dependency
- `ruby_wasm` gem (build-time only, needed to rebuild the sandbox image)

## Setup

Install from RubyGems:

```bash
gem install security_box
```

Or add to your `Gemfile`:

```ruby
gem "security_box"
```

The gem ships a prebuilt sandbox image (`lib/security_box/assets/security_box.wasm`,
about 110MB), so no network access or build tools are needed at install or at
runtime.

### Rebuilding the image (development only)

If you change `lib/security_box/guest/*.rb` or bump the pinned ruby.wasm
release, repack the sandbox image:

```bash
bundle install
bundle exec rake security_box:build_image
```

This downloads the pinned ruby.wasm release (`2.10.1`, see the `Rakefile`) and
packs it with the guest script into `lib/security_box/assets/security_box.wasm`.
The task skips repacking when the image is already fresh. The image is not
committed to git.

You can point the library at a different image with the `SECURITY_BOX_IMAGE`
environment variable or by passing `image_path:` in the configuration — useful
for custom-built images.

## Usage

### Quick start

```ruby
require "security_box"

result = SecurityBox.eval("puts 'hello'; 40 + 2")

result.status    # => :ok
result.value     # => 42
result.stdout    # => "hello\n"
result.fuel_used # => > 0
result.duration_ms # => 257.0 (approx; dominated by the ruby.wasm boot)
```

### Warming up

The first `eval` in a process pays either the cold WebAssembly compilation of the image
(~15s) or a fast deserialize from the compiled-module disk cache (~0.5s) plus the engine
setup. The cache lives in `~/.cache/security_box/modules` (override with
`SECURITY_BOX_CACHE_DIR`), is keyed by the image content, and is fully best effort —
on any miss or corruption the module is simply recompiled. Call `SecurityBox.warmup`
ahead of time (e.g., at boot) to pay that cost up front — every subsequent `eval` then
only pays the ~260ms guest boot:

```ruby
SecurityBox.warmup

SecurityBox.eval("40 + 2").value # => 42 (~260ms, no cold compile)
```

`#eval` warms the same caches lazily on first use, so calling `warmup` is a pure
optimization — behavior and results are identical without it. It accepts the same
options as `Configuration.build` and is safe to call multiple times.

### Multiple evaluations on the same sandbox

```ruby
sandbox = SecurityBox::Sandbox.new
sandbox.eval("1 + 1").value # => 2
sandbox.eval("3 * 3").value # => 9
```

### Per-call limits

Options can be passed per call (derived from the configuration without mutating it):
`timeout_ms`, `fuel`, `memory_size`, `stdout_limit`, `stderr_limit`.

```ruby
# Wall-clock limit via epoch interruption
SecurityBox.eval("while true; end", timeout_ms: 500).status # => :timeout

# Deterministic CPU budget
SecurityBox.eval("while true; end", fuel: 1_000_000).status # => :fuel_exhausted

# Memory limit
SecurityBox.eval(
  "a = []; loop { a << ('x' * 1024) }",
  memory_size: 128 * 1024 * 1024,
  timeout_ms: 15_000
).status # => :memory_limit

# Output truncation
SecurityBox.eval('1000.times { print "x" * 1000 }', stdout_limit: 4096).stdout.bytesize # => <= 4096
```

### Errors from guest code

Exceptions raised by guest code are a *result*, not a sandbox failure:

```ruby
result = SecurityBox.eval("def boom; raise ArgumentError, 'boom'; end; boom")

result.status                    # => :error
result.error["class"]            # => "ArgumentError"
result.error["message"]          # => "boom"
result.error["backtrace"]        # => ["sandbox:1:in 'Object#boom'", "sandbox:1:in '<main>'"]
```

The backtrace contains guest frames only (sandbox-internal locations, capped at
20 frames) — nothing from the host filesystem leaks.

### Named profiles

Reusable configurations registered once and spawned as often as needed:

```ruby
SecurityBox.register(:default) do |c|
  c.fuel 10_000_000_000
  c.timeout_ms 2_000
end

SecurityBox.register(:lean, from: :default) do |c|
  c.fuel 2_000_000_000        # boot alone costs ~1e9; see the fuel notes below
  c.timeout_ms 500
end

box = SecurityBox.spawn(:lean)               # Sandbox from the profile
box.eval("40 + 2").value                     # => 42

SecurityBox.spawn(:lean, timeout_ms: 100)    # per-call override (profile unchanged)
SecurityBox.spawn                            # default configuration
```

Profiles are immutable: duplicate names and unknown names raise
`SecurityBox::InvalidConfiguration`; overrides never mutate the profile.
`SecurityBox::Configuration#fingerprint` gives every configuration a stable
identity (equal settings → equal fingerprint), used to share runtime artifacts.

### Configuration

`SecurityBox::Configuration` is immutable; use `.build` to create and `#with` to derive:

```ruby
config = SecurityBox::Configuration.build(
  fuel: 10_000_000_000,             # deterministic CPU budget
  timeout_ms: 2_000,                # wall-clock limit (epoch interruption)
  memory_size: 512 * 1024 * 1024,   # wasm linear memory limit
  stdout_limit: 1 << 20,            # stdout capture capacity in bytes
  stderr_limit: 1 << 16,            # stderr capture capacity in bytes
  epoch_interval_ms: 25,            # epoch timer granularity
  env: { "LANG" => "C" }            # guest environment (empty by default)
)

lean = config.with(timeout_ms: 500, fuel: 5_000_000)
sandbox = SecurityBox::Sandbox.new(lean)
```

### Result statuses

| Status | Meaning |
|---|---|
| `:ok` | guest code ran and returned a value |
| `:error` | guest code raised an exception (see `#error`; includes `backtrace`) |
| `:timeout` | interrupted by the epoch deadline (wall clock); `fuel_used` is `nil` (epoch traps restore fuel to the checkpoint) |
| `:fuel_exhausted` | CPU budget exhausted |
| `:memory_limit` | exceeded the store `memory_size` (wasm trap or guest `NoMemoryError`) |
| `:sandbox_error` | sandbox failure (unexpected trap, missing/invalid envelope, `memory_size` below the image's minimum) |

Values are JSON-serialized; non-serializable objects are returned as their `inspect`
string.

## Isolation guarantees

| Probe inside the guest | Result |
|---|---|
| `File.write("/etc/passwd", ...)` | `Errno::ENOENT` (guest does not see the host FS) |
| `Dir["/*"]` | `[]` (empty root) |
| `system("ls")` / backticks / `IO.popen` / `Process.spawn` | `SecurityError` (hardening prelude) |
| `Kernel#open(...)` | `SecurityError` (pipe form; use `File.open`) |
| `fork` | `NotImplementedError` |
| `Thread.new` | `NotImplementedError` (WASI p1 has no threads) |
| `require "socket"` | `LoadError` (no network) |
| `ENV` | `{}` (token read and scrubbed by the prelude) |
| forge `out.json` via `at_exit` / fake sentinel | rejected (token mismatch → `:sandbox_error`) |
| infinite loop | killed by epoch deadline or fuel budget |

Notes:

- The guest Ruby version is the one from ruby.wasm (4.0), not necessarily the host's.
- Concurrency: `invoke` holds the GVL, so executions serialize per host process. Scale
  horizontally with multiple processes (e.g., Puma workers); a stuck guest still can't
  hang the process thanks to the epoch deadline.
- Ractor note: wasmtime `Engine`/`Module` are Ractor-shareable and Ractors run wasm in
  parallel (measured ≈3.6x with 4 Ractors on 6 cores); a supported Ractor pool is on
  the roadmap (see `docs/plan/stages/stage_3.md`).
- Memory: the packed image declares a 1528-page (~95.5 MiB) minimum; `memory_size`
  below that fails instantiation (reported as `:sandbox_error`). Practical minimum is
  ~128–144MB for small workloads; the 512MB default leaves comfortable headroom.
- Fuel budgeting: compute workloads burn ~4–8e9 fuel/s (tight loops up to ~8.4e9/s)
  and every eval costs ~1e9 fuel for boot — see the calibration table in
  `docs/plan/stages/stage_3.md`. Consequently `fuel` below ~1e9 cannot even boot, and
  `timeout_ms` below ~300ms times out during the guest boot (~500ms is a practical
  floor).

## Running the tests

```bash
bundle exec rspec spec/
```

The integration suite runs against the real ruby.wasm image. If the image at
`lib/security_box/assets/security_box.wasm` is missing, the suite builds it
automatically before running (this may take a few minutes the first time).

## Releasing

1. Rebuild the image if needed: `bundle exec rake security_box:build_image`
   (also runs automatically before `rake build`/`rake release`).
2. Verify it is fresh: `bundle exec rake security_box:verify_image`
3. Run the suite: `bundle exec rake spec`
4. Build and publish: `bundle exec rake release` (tags git and pushes the gem
   to RubyGems.org)

## Learning spike

`bin/spike.rb` validates the feasibility questions (Q1–Q9) against the built image and
prints a timing report:

```bash
bundle exec ruby bin/spike.rb
```

## Documentation

- `docs/PLAN.md` — architecture, roadmap and threat model
- `docs/plan/stages/stage_1.md` — stage 1 findings and measured numbers
- `docs/plan/stages/stage_2.md` — stage 2 findings (hardening prelude, result-channel
  integrity, compiled-module disk cache)
- `docs/plan/stages/stage_3.md` — stage 3 findings (named profiles, Ractor
  parallelism, memory floor, fuel calibration, backtrace)
