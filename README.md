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

1. A `ruby.wasm` image is built from the pinned Ruby 4.0 source with the guest
   gems of `lib/security_box/guest_ext` statically linked (`rbwasm build`),
   then packed with the guest entrypoint (`lib/security_box/guest/main.rb`)
   plus a hardening prelude (`lib/security_box/guest/prelude.rb`). The
   `sb_rpc` gem declares the `sb`/`call` wasm import used by the host RPC
   channel (see "Host RPC (code mode)" below).
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
about 50MB), so no network access or build tools are needed at install or at
runtime.

### Rebuilding the image (development only)

If you change `lib/security_box/guest/*.rb` or anything under
`lib/security_box/guest_ext/` (guest gems), rebuild the sandbox image:

```bash
bundle install
bundle exec rake security_box:build_image
```

The first build downloads the Ruby source tarball, wasi-sdk and binaryen into
`build/` (network required, cached afterwards), builds Ruby 4.0 with the guest
gems statically linked and packs `lib/security_box/guest` as `/src`. The task
skips rebuilding when the image is already fresh. The image is not committed to
git.

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
`timeout_ms`, `fuel`, `fuel_ms`, `memory_size`, `stdout_limit`, `stderr_limit`,
`mounts`.

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

### Host RPC (code mode)

Guest code can call host-registered handlers with a regular, **blocking**
function call — the shape model-generated "code mode" agents need:

```ruby
SecurityBox.register(:agent) do |c|
  c.rpc "github.search" => ->(args) { mcp.call_tool("github", "search", args) }
  c.rpc "github.get"    => ->(args) { mcp.call_tool("github", "get_file", args) }
  c.fuel_ms 200
  c.timeout_ms 5_000   # covers boot + guest compute + handler time
end

box = SecurityBox.spawn(:agent)
box.eval(<<~CODE)
  hits = SB.call("github.search", q: "ruby wasm").items
  SB.call("github.get", path: hits.first.path)
CODE
```

- `SB.call(name, args)` blocks inside the sandbox (a wasm import provided by
  the statically linked `sb_rpc` gem) while the host executes the handler;
  from the guest's perspective it is just a function returning a value.
- Handlers receive the JSON-parsed args (string keys) and must return a
  JSON-serializable value (non-serializable results surface as inspect
  strings).
- A raising handler becomes a guest-rescuable `SB::ToolError`
  (`SB::UnknownTool` for unregistered names) carrying only `class` +
  `message` — no backtrace, no host details. Calling an RPC on a sandbox
  with no handlers configured is also a clean, rescuable error.
- `Result#rpcs` carries the frozen per-eval transcript
  (`{"name", "args", "ok", "result"|"error"}`) for agent debugging.
- Limits: at most 1000 calls per eval and 1MiB per response.
- Handlers are host-only state: excluded from `#fingerprint`, not supported
  on `RactorPool` (they cannot cross a Ractor boundary), and must be
  thread-safe when a `Pool` is used concurrently.
- Per-call override (replaces, like `env:`):
  `SecurityBox.eval(code, rpcs: { "calc" => ->(args) { ... } })`.

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

### Folder mounts

Host folders can be mounted into the sandbox explicitly. **Mounts are read-only
by default**; `mount_rw` is the opt-in writable form:

```ruby
SecurityBox.register(:reader) do |c|
  c.mount    "./data" => "/data"   # read-only (host path expanded at DSL time)
  c.mount_rw "./state" => "/state" # opt-in writable
end

box = SecurityBox.spawn(:reader)
box.eval('File.read("/data/input.csv")')      # guest reads mounted content
box.eval('File.write("/state/last.txt", Time.now.to_i)')

# Per-call override (replaces the configuration's mounts, like env:)
SecurityBox.eval('File.read("/data/a.txt")',
                 mounts: [{ host: "./data", guest: "/data", mode: :read_only }])
```

Rules (violations raise `SecurityBox::InvalidConfiguration` at registration):

- A mount is one `{host:, guest:, mode:}` pair; `mode` is `:read_only` or
  `:read_write` and the DSL defaults to read-only.
- Guest paths must be absolute and normalized, must not overlap the reserved
  `/work` (sandbox tmpdir), `/usr` (embedded stdlib) or `/src` (entrypoint)
  trees — exact or nested — and must be unique.
- At most 16 mounts per configuration.
- The host path must exist and be a directory at eval time; otherwise the eval
  returns `:sandbox_error` with a `security_box:` note on stderr (instead of
  raising).

Security notes:

- **A mounted folder's content is fully readable by guest code** — only mount
  directories whose content you are willing to expose to the executed code.
- Read-only mounts are enforced by wasmtime: writes fail guest-side with
  `Errno::EPERM` and the host directory is never touched. Symlinks inside a
  mounted directory cannot escape it (wasmtime caps path resolution at the
  preopen root), and guest code cannot create symlinks at all.
- Mounted content can also be **written by the guest** in `mount_rw` mounts —
  treat a writable mount as part of the guest's blast radius.

### Configuration

`SecurityBox::Configuration` is immutable; use `.build` to create and `#with` to derive:

```ruby
config = SecurityBox::Configuration.build(
  fuel: 10_000_000_000,             # deterministic CPU budget
  fuel_ms: nil,                     # or a millisecond-based budget (mutually exclusive with fuel)
  timeout_ms: 2_000,                # wall-clock limit (epoch interruption)
  memory_size: 512 * 1024 * 1024,   # wasm linear memory limit
  stdout_limit: 1 << 20,            # stdout capture capacity in bytes
  stderr_limit: 1 << 16,            # stderr capture capacity in bytes
  epoch_interval_ms: 25,            # epoch timer granularity
  env: { "LANG" => "C" },           # guest environment (empty by default)
  mounts: [],                       # host-folder mounts (see "Folder mounts")
  rpcs: {}                          # name => callable host RPC handlers
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
| `File.write` into a read-only mount | `Errno::EPERM` (wasmtime-enforced; host dir untouched) |
| symlink escape from a mounted directory | `Errno::EPERM` (path resolution capped at the preopen root) |
| `system("ls")` / backticks / `IO.popen` / `Process.spawn` | `SecurityError` (hardening prelude) |
| `Kernel#open(...)` | `SecurityError` (pipe form; use `File.open`) |
| `fork` | `NotImplementedError` |
| `Thread.new` | `NotImplementedError` (WASI p1 has no threads) |
| `require "socket"` | `LoadError` (no network) |
| `ENV` | `{}` (token read and scrubbed by the prelude) |
| `SB.call("missing")` | `SB::UnknownTool` (guest-rescuable; host never crashes) |
| `SB.call` with no handlers configured | `SB::UnknownTool` ("no RPC handlers are configured…") |
| handler raising | guest sees `SB::ToolError` with `class` + `message` only |
| >1000 RPC calls or >1MiB result | `SB::ToolError` (guest-rescuable, host-side enforced) |
| forge `out.json` via `at_exit` / fake sentinel | rejected (token mismatch → `:sandbox_error`) |
| infinite loop | killed by epoch deadline or fuel budget |

Notes:

- The guest Ruby version is the one from ruby.wasm (4.0), not necessarily the host's.
- Mounts widen the trust surface: a mounted folder's content is fully readable by
  guest code (see "Folder mounts" above). Read-only by default; nothing outside
  `/work` is writable without an explicit `mount_rw`.
- Concurrency: `invoke` holds the GVL, so executions on threads serialize — use
  `RactorPool` (below) for parallelism inside one process, or scale horizontally with
  multiple processes (e.g., Puma workers). A stuck guest still can't hang the process
  thanks to the epoch deadline.
- Ractor: wasmtime `Engine`/`Module` are Ractor-shareable and Ractors run wasm in
  parallel — measured ≈1.9x wall-time speedup at 4 workers on 6 cores through
  `RactorPool` (see `docs/plan/stages/stage_3.md` and `stage_4.md`).
- Memory: the image (stage-6 `rbwasm build` flow) declares a ~576-page (~36 MiB)
  minimum; `memory_size` below that fails instantiation (reported as
  `:sandbox_error`). Practical minimum is ~48–64MB for small workloads; the
  512MB default leaves comfortable headroom.
- Fuel budgeting: compute workloads burn ~4–8e9 fuel/s (tight loops up to ~8.4e9/s)
  and every eval costs ~1e9 fuel for boot — see the calibration table in
  `docs/plan/stages/stage_3.md`. Consequently `fuel` below ~1e9 cannot even boot, and
  `timeout_ms` below ~300ms times out during the guest boot (~500ms is a practical
  floor). Prefer thinking in milliseconds? Use `fuel_ms` (below).

## Concurrency

Two pools are available, with honestly different guarantees (measured in stage 4 —
`invoke` holds the GVL, so a long-lived `:worker` instance is impossible on the current
wasmtime-rb; one wasm boot per eval stays on the hot path):

### `Pool` — bounded concurrency on threads

```ruby
pool = SecurityBox.pool(:lean, size: 4)
pool.eval("40 + 2").value    # => 42
pool.checkout { |sandbox| sandbox.eval("1 + 1") }
pool.metrics                 # => {size:, created:, evals:, total_ms:, avg_ms:}
pool.shutdown
```

Caps concurrent evals at `size` and reuses sandbox objects, but evals serialize on the
GVL — one at a time.

### `RactorPool` — real parallelism

```ruby
pool = SecurityBox.ractor_pool(:lean, size: 4)
pool.eval("40 + 2").value    # => 42
pool.shutdown
```

Worker Ractors share one Engine + compiled Module and run wasm truly in parallel
(~1.9x wall-time speedup at 4 workers on 6 cores; measured ≈0.53 parallel/serial wall
ratio across 1M–4M-iteration workloads). Per-call overrides, user errors, timeouts and
fuel exhaustion behave exactly like `Sandbox#eval`, and the worker survives traps and
keeps serving. Costs one module deserialize at creation (~0.5s via the disk cache);
each eval still pays the ~240ms guest boot.

### `fuel_ms` — rate-based fuel budgeting

Instead of counting raw fuel, budget approximate wall-time of compute:

```ruby
config = SecurityBox::Configuration.build(fuel_ms: 100) # ≈100ms of compute + boot allowance
SecurityBox.spawn(config).eval("i = 0; while i < 5_000_000; i += 1; end").status
# => :fuel_exhausted (5M tight iterations ≈ 2.4e9 fuel > the 100ms budget)
```

`fuel_ms` converts to fuel with the conservative stage-3 calibration rate
(4e6 fuel/ms ≈ 4e9 fuel/s) plus a ~1e9 boot allowance (`Configuration#effective_fuel`).
The epoch `timeout_ms` remains the mandatory wall-clock backstop. `fuel` and `fuel_ms`
are mutually exclusive in the builder DSL and in `#with` overrides; a `fuel_ms`
configuration can be switched back with `with(fuel_ms: nil, fuel: ...)`.

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

## Samples

- [`samples/ruby_llm/reader_agent`](samples/ruby_llm/reader_agent/README.md) — an
  LLM agent built with [RubyLLM](https://github.com/crmne/ruby_llm) whose code-execution
  tool runs model-generated Ruby inside the sandbox, demonstrating folder mounts
  (read-only vs read-write) end to end.
- [`samples/ruby_llm/context7_code_mode`](samples/ruby_llm/context7_code_mode/README.md) —
  a RubyLLM code-mode agent whose sandbox code reaches the hosted
  [Context7](https://context7.com) MCP server through `SB.call`: host RPC
  handlers proxy the MCP tools (streamable HTTP + bearer auth), so the API
  key never crosses the sandbox boundary. Includes a no-LLM smoke script
  that exercises the RPC↔MCP wiring.

## Documentation

- `docs/PLAN.md` — architecture, roadmap and threat model
- `docs/plan/stages/stage_1.md` — stage 1 findings and measured numbers
- `docs/plan/stages/stage_2.md` — stage 2 findings (hardening prelude, result-channel
  integrity, compiled-module disk cache)
- `docs/plan/stages/stage_3.md` — stage 3 findings (named profiles, Ractor
  parallelism, memory floor, fuel calibration, backtrace)
- `docs/plan/stages/stage_4.md` — stage 4 findings (worker-mode feasibility, pools,
  `fuel_ms`)
- `docs/plan/stages/stage_5.md` — stage 5 findings (folder mounts: read-only
  enforcement, reserved-path collisions, symlink escapes, mount cost)
- `docs/plan/stages/stage_6.md` — stage 6 findings (blocking host RPC via a
  wasm import, `SB.call` code-mode contract, epoch semantics, new image
  build flow)
