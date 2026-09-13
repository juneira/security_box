# Plan: `security_box` — sandbox for untrusted Ruby with ruby.wasm + wasmtime

## 1. Goal

Provide a Ruby library (`security_box`) that runs **untrusted** Ruby code inside a
WebAssembly sandbox (ruby.wasm), using the [`wasmtime`](https://github.com/bytecodealliance/wasmtime-rb)
gem as an embedded runtime in the host Ruby process.

Core requirements:

1. **Real isolation**: the guest code has no network, cannot see the host filesystem,
   cannot create processes, and cannot escape the wasm runtime.
2. **Mandatory limits**: time (wall-clock), CPU (fuel), memory, output size.
3. **Reusable configurations**: an immutable configuration object, cheap to clone, that
   can be shared by several sandboxes and used as a named "profile".
4. **Spawn several sandboxes easily**: predictable creation cost, pool of hot instances,
   and concurrent execution (wasmtime-rb `invoke` releases the GVL).

### Non-goals (v1)

- Running gems with arbitrary native extensions inside the guest (only pure-Ruby gems
  packaged into the image).
- Threads inside the guest (ruby.wasm/wasip1 does not support `Thread`).
- WASI Preview 2 components (we will use Preview 1, which is what ruby.wasm publishes today).
- High *throughput* performance per sandbox — we prioritize isolation and predictability.

---

## 2. How execution works (validated fundamentals)

- ruby.wasm publishes prebuilt binaries per version + profile
  (`ruby-4.0-wasm32-unknown-wasip1-full`, `...-minimal`).
- To run a script, we pack the runtime + stdlib + our "supervisor" script into a single
  `.wasm` with an embedded VFS (`rbwasm pack` / `RubyWasm::Packager` + wasi-vfs). Result: **one
  self-contained file**, no need to pre-open host directories at runtime.
- The module exposes `_start` (WASI command). On the host:

```ruby
engine   = Wasmtime::Engine.new(epoch_interruption: true, consume_fuel: true)
mod      = Wasmtime::Module.from_file(engine, image_path)   # or .deserialize_file
linker   = Wasmtime::Linker.new(engine)
Wasmtime::WASI::P1.add_to_linker_sync(linker)

wasi = Wasmtime::WasiConfig.new
  .set_stdin_string("")                       # never inherit host stdin
  .set_stdout_buffer(String.new, 1 << 20)     # captured + limited output
  .set_stderr_buffer(String.new, 1 << 16)
  .set_argv(["ruby", "/src/main.rb"])
  .set_env({})

store = Wasmtime::Store.new(engine, wasi_p1_config: wasi,
                            limits: { memory_size: 64 * 1024 * 1024 })
instance = linker.instantiate(store, mod)
instance.invoke("_start")                     # releases the GVL during execution
```

- Available limits we will use: `Engine.new(consume_fuel:, epoch_interruption:, max_wasm_stack:)`,
  `Store.new(limits: { memory_size:, instances:, memories:, tables:, table_elements: })`,
  `store.set_fuel`, `store.set_epoch_deadline`, `store.linear_memory_limit_hit?`, `store.close`.
- Structured result: the guest writes a JSON envelope into a directory that is **exclusive to
  the sandbox**, mounted as `/work` (read-write). The host reads `/work/out.json`. This avoids
  the pitfalls of "forging" delimiters on stdout.

---

## 3. Architecture

```
Configuration (immutable, reusable)
        │  fingerprint
        ▼
   Image (build + cache) ──► .wasm file ──► Runtime (Engine + compiled Module, cwasm cache)
        │                                              │
        └────────────────► Sandbox (Store + Instance) ◄┘        Pool (hot instances)
                                     │
                                  Result
```

| Layer | Responsibility |
|---|---|
| `Configuration` | All sandbox parameters. Immutable; `#with(**changes)` returns a copy. |
| `Image` / `ImageBuilder` | Resolves/builds the `.wasm` (runtime + stdlib + gems + `guest/main.rb`), cached by fingerprint. |
| `Runtime` | `Wasmtime::Engine` + compiled `Module` (and `.cwasm` cache) per config fingerprint. Shared across sandboxes and threads. |
| `Sandbox` | One `Store` + `Instance` per execution (or per worker). Applies WASI config, limits and deadlines. |
| `Result` | `stdout`, `stderr`, `value`, `error`, `duration_ms`, `fuel_used`, `status`. |
| `Pool` | Keeps N hot sandboxes per profile, returns them to the pool or discards (`store.close`) per limits. |

---

## 4. Public API (target)

```ruby
# Named, reusable profiles
SecurityBox.register(:default) do |c|
  c.ruby_version "4.0"
  c.profile      :full                 # :full | :minimal
  c.stdlib       %w[json yaml]         # extra components to keep (:minimal starts empty)
  c.gems         []                    # pure-Ruby gems allowlist, baked into the image

  c.memory_limit 64 * 1024 * 1024
  c.fuel         50_000_000
  c.timeout_ms   2_000                 # epoch interruption
  c.output_limit 1 << 20
  c.max_wasm_stack 1 << 20

  c.env          "LANG" => "C"
  c.mount        "./data" => "/data"   # read-only by default
  c.mount_rw     nil                   # nothing writable outside /work

  c.mode         :oneshot              # :oneshot | :worker (phase 4)
  c.hardening    :standard             # prelude that removes dangerous APIs
end

SecurityBox.register(:lean, from: :default) do |c|
  c.profile :minimal
  c.fuel    5_000_000
  c.timeout_ms 500
end

# Usage: spawn as many as you want, concurrently
box = SecurityBox.spawn(:lean)              # or SecurityBox.spawn(:default, fuel: 1_000)
res = box.eval(<<~RUBY)
  require "json"
  puts JSON.generate({ok: true})
  exit 0
RUBY

res.status      # => :ok | :error | :timeout | :fuel_exhausted | :memory_limit | :output_truncated
res.stdout      # => "{\"ok\":true}\n"
res.value       # => return value (JSON-serializable)
res.error       # => {class:, message:, backtrace:} when :error
res.duration_ms # => 12.4
res.fuel_used   # => 1_284_311

# Pool for frequent spawns
pool = SecurityBox::Pool.new(:default, size: 8, max_age: 100)
pool.checkout { |sandbox| sandbox.eval(code) }
```

`Configuration#with` never mutates the original; `Runtime` is memoized by fingerprint, so a
thousand `spawn`s of the same config share the same compiled `Engine`/`Module`.

---

## 5. Isolation and limits (defense matrix)

| Threat | Defense |
|---|---|
| Infinite loop / CPU | `epoch_interruption` + `store.set_epoch_deadline` (wall-clock) **and** `consume_fuel` + `store.set_fuel` (deterministic budget) |
| Memory (bomb) | `limits: { memory_size: }` + check of `store.linear_memory_limit_hit?` |
| Stack overflow / recursion | `max_wasm_stack` + rescue of `SystemStackError` in the guest |
| Host disk/RAM exhaustion from many instances | `Pool` with a maximum size + `store.close` on return/discard |
| Network | Never call `inherit_network`/`allow_tcp`/`allow_udp` — ruby.wasm WASI p1 already has no sockets |
| Host filesystem | No pre-opened directories by default; only `/work` (tmpdir per sandbox) and explicit mounts, read-only by default |
| Processes / `system` / backticks / fork | Nonexistent in wasip1; the `hardening` prelude also removes whatever is left |
| stdout flood | `set_stdout_buffer(buf, capacity)` — truncates with a configurable limit |
| ENV/argv leak | Explicit `set_env({})`; only allowed variables |
| Runtime escape | There are no native syscalls in wasmtime p1 without an explicit import; we keep imports restricted to WASI |

Extra hardening (optional, `:standard`): a prelude loaded before user code that
cleans `ENV`, refines/removes `File` write ops when there is no RW mount, disables dynamic
`Kernel#require` from outside the image, and applies `$stdout.sync = true`. **Primary isolation
is WASI, not the prelude** — the prelude is defense in depth.

---

## 6. Host ↔ guest protocol

### `:oneshot` mode (default, Phase 2)

1. Host creates the sandbox-exclusive tmpdir, writes `/work/code.rb` (or `in.json`).
2. Mounts `/work` read-write via `set_mapped_directory(tmpdir, "/work", :read_write)`.
3. Instantiates and invokes `_start`; the guest (`lib/security_box/guest/main.rb`):
   - reads `/work/code.rb`, evaluates it inside a `begin/rescue` with `$stdout` redirected,
   - serializes the envelope `{ok, value, error, backtrace, duration_ms}` into `/work/out.json`,
   - exits with `exit 0` (even on user error — a user error is a *result*, not a sandbox failure).
4. Host reads `/work/out.json`, applies `store.close`, removes the tmpdir.

Advantage: a fresh wasm process per execution ⇒ zero residual state between executions, no
need for a "reset".

### `:worker` mode (Phase 4, only if the benchmark justifies it)

A long-lived instance that processes several requests, to amortize the instantiation cost.
Candidate channels, in order of preference to validate in the spike:

1. **FIFOs** pointed to by `set_stdin_file` / `set_stdout_file` (host writes requests, guest
   reads blocking; host reads responses from another thread — `invoke` releases the GVL).
2. **Files with double buffering** in `/work` + short polling (simple and portable fallback).

We will only adopt it if the instantiation cost measured in M0 is high (e.g., > 10 ms). Otherwise,
the `:oneshot` mode + a pre-warming pool with `InstanceAllocationStrategy::Pooling` solves it.

---

## 7. Reusable configurations (design details)

- `Configuration` is `Data`/frozen; `#with` uses a shallow merge per group (`image:`, `limits:`,
  `wasi:`, `runtime:`), and the fingerprint is a `Digest::SHA256` of the normalized hash.
- Two levels of cache derived from the fingerprint:
  - `~/.cache/security_box/images/<sha>.wasm` — packed image;
  - `~/.cache/security_box/modules/<sha>-<precompile_key>.cwasm` — compiled module
    (`Module#serialize` + `deserialize_file`, key from `engine.precompile_compatibility_key`).
- `Runtime` keeps the `Engine` + `Module` in a global registry (`SecurityBox::Runtime.registry`),
  protected by a mutex; `Engine`/`Module` are thread-safe and reusable.
- `spawn` never builds anything at runtime: if the fingerprint is not in cache and the build is
  disabled (production), it raises `SecurityBox::ImageMissing`. Build is an explicit step
  (`rake security_box:build` / `SecurityBox.build_all!`).
- Named profiles allow `SecurityBox.spawn(:lean)`, `SecurityBox.spawn(:lean, fuel: 1000)`, and
  `SecurityBox::Pool.new(:lean)` — all sharing the same image/module when possible.

---

## 8. File structure

```
lib/security_box.rb                       # public API: register/spawn/build_all!
lib/security_box/configuration.rb         # immutable + #with + fingerprint
lib/security_box/registry.rb              # named profiles + runtime/image caches
lib/security_box/image.rb                 # resolution + fingerprint + cache
lib/security_box/image_builder.rb         # rbwasm pack / RubyWasm::Packager
lib/security_box/runtime.rb               # Engine + Module (+ cwasm cache)
lib/security_box/sandbox.rb               # Store/Instance, WASI config, limits, eval
lib/security_box/result.rb                # result envelope
lib/security_box/errors.rb                # SecurityBox::Error, Timeout, FuelExhausted, ...
lib/security_box/pool.rb                  # pool of hot sandboxes
lib/security_box/guest/main.rb            # packed script (entrypoint _start)
lib/security_box/guest/prelude.rb         # optional hardening
lib/security_box/version.rb
exe/security_box                          # CLI: security_box eval / build / doctor
security_box.gemspec                      # deps: wasmtime (runtime), ruby_wasm (build, optional)
spec/…                                    # unit + integration + escape matrix + benchmarks
```

Dependencies: `wasmtime` (runtime, precompiled gem; add platforms to the lock:
`x86_64-linux`, `aarch64-linux`, `arm64-darwin`, `x86_64-darwin`), `ruby_wasm` (build only),
`json` (stdlib).

---

## 9. Phases

### M0 — Feasibility spike (1–2 days)
- Download `ruby-4.0-wasm32-unknown-wasip1-full`, pack `guest/main.rb` with `rbwasm pack`.
- Run via wasmtime-rb: basic `puts`, stdout capture, JSON required from inside the wasm.
- Validate interruption: infinite loop killed by `epoch`, and by `fuel`.
- Measure: image size, cold/warm `_start` time, memory peak per instance.
- **Exit criterion**: documented numbers in `docs/benchmarks.md` + `:oneshot` vs `:worker` decision.

### M1 — Core
`Configuration`, `Runtime`, one-shot `Sandbox#eval`, `Result`, errors, `register/spawn` API.
Unit + integration tests.

### M2 — Isolation and limits
Fuel/epoch/memory/output-limit, read-only mounts, sanitized env, `/work` per sandbox, hardening
prelude, `store.close`, trap translation (`Wasmtime::Trap`) into `Result#status`.

### M3 — Images and cache
`ImageBuilder` (version, profile, stdlib components, gems allowlist), fingerprint, disk cache,
compiled module cache, rake tasks, `security_box build`.

### M4 — Pool and concurrency
`Pool` with size/limits, pre-warming, metrics (spawns, average time, discards), concurrent load
test; `:worker` mode spike if justified by M0.

### M5 — DX and operations
CLI (`eval`, `build`, `doctor`), structured logs, optional telemetry, gem release, docs
(`docs/SECURITY.md` with the threat model), benchmarks in CI.

---

## 10. Tests

- **Escape matrix** (each item becomes a test that must yield a `Result`, never break the
  host): `loop {}`, `until false`, `"a" * 10**12`, `eval("`ls`")`, `system("ls")`, `fork`,
  `File.write("/etc/passwd")`, `Dir["/"]`, `ENV`, `require "socket"`, `require "open-uri"`,
  `Thread.new`, `exit!`, `at_exit`, `Process.kill`, giant `Random`, hostile `Marshal.load`,
  infinite recursion, `puts "x" * 10**9`, `String#*`, catastrophic `Regexp`, `$0`/`__FILE__`.
- **Limits**: each exceeded limit produces the correct `status` and releases resources
  (`store.close`).
- **Configs**: `#with` does not mutate; equal fingerprints reuse the Runtime; different configs
  are isolated; concurrent `spawn` on N threads with no memory leak.
- **Benchmarks**: spawn latency p50/p99, throughput, memory per instance — guard rail in CI
  (fails if it regresses > X%).

---

## 11. Risks and open questions

1. **ruby.wasm instantiation cost** (the "full" image is large) — defines whether we need the
   worker mode. Mitigation: precompiled module + pooling allocator + instance pool.
2. **Image size** may make caching unfeasible in small containers — mitigate with the
   `:minimal` profile + `stdlib` allowlist and removal of unused components.
3. **FIFOs** in worker mode may hang on open in some platforms; Windows is out of scope for
   the worker mode.
4. **Version fidelity**: the guest Ruby is the one from ruby.wasm (4.0/3.4), not necessarily the
   host one — document clearly and allow configuring per profile.
5. **Return value serialization**: JSON is safe but limited (complex objects become
   `String`/`nil`). Alternative: `Marshal` to a file in `/work` — but **never** deserialize on
   the host; keep JSON in v1.
6. **wasmtime traps** (`Wasmtime::Trap`) need to be mapped to `status` without leaking internal
   runtime details in error messages.
7. **Observability**: how to correlate executions (request id) — inject via guest env and
   echo it in the envelope.
