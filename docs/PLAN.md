# Plan: `security_box` — sandbox for untrusted Ruby with ruby.wasm + wasmtime

> **Status**: stages 1–4 are delivered and shipped as gem releases 0.1.0–0.4.0.
> This document reflects what actually shipped; the measured evidence lives in the
> stage documents (`docs/plan/stages/`). The roadmap in §9 carries the remaining
> scope: stage 5 (folder mounts) is next, followed by the image builder (M3) and
> the CLI (M5), with a backlog of revisit triggers.

## 1. Goal

Provide a Ruby library (`security_box`) that runs **untrusted** Ruby code inside a
WebAssembly sandbox (ruby.wasm), using the [`wasmtime`](https://github.com/bytecodealliance/wasmtime-rb)
gem as an embedded runtime in the host Ruby process.

Core requirements:

1. **Real isolation**: the guest code has no network, cannot see the host filesystem
   (except explicitly mounted folders), cannot create processes, and cannot escape
   the wasm runtime.
2. **Mandatory limits**: time (wall-clock), CPU (fuel), memory, output size.
3. **Reusable configurations**: an immutable configuration object, cheap to clone,
   usable as a named "profile" and as a cache key (fingerprint).
4. **Easy spawning and concurrency**: predictable per-eval cost, a bounded `Pool`
   for resource bounding, and real parallelism via `RactorPool` (`invoke` holds the
   GVL, so threads alone cannot parallelize executions).

### Non-goals (v1)

- Running gems with arbitrary native extensions inside the guest (only pure-Ruby gems
  packaged into the image).
- Threads inside the guest (ruby.wasm/wasip1 does not support `Thread`).
- WASI Preview 2 components (we use Preview 1, which is what ruby.wasm publishes today).
- Long-lived worker instances: rejected with evidence on wasmtime-rb 48 — `invoke`
  holds the GVL while the guest computes *and* while it is blocked on a WASI read, and
  epoch deadlines never fire inside a blocking syscall (stage 4 Q1/Q2). Revisit only
  when wasmtime-rb ships GVL-releasing/async WASI.
- High *throughput* performance per sandbox — we prioritize isolation and predictability.

---

## 2. How execution works (validated)

- ruby.wasm publishes prebuilt binaries per version + profile
  (`ruby-4.0-wasm32-unknown-wasip1-full`). We pack the runtime + stdlib + the guest
  entrypoint + hardening prelude into a single self-contained `.wasm` with an embedded
  VFS (`rbwasm pack`; `/usr` and `/src` are embedded, read-only to the guest).
- Per `#eval` (`:oneshot`, the only mode): the host creates a sandbox-exclusive tmpdir,
  writes the user code to it, mounts it read-write as `/work`, generates a per-eval
  random token delivered via `SB_TOKEN`, then boots a fresh wasm instance:

```ruby
engine   = Wasmtime::Engine.new(epoch_interruption: true, consume_fuel: true)
mod      = Wasmtime::Module.from_file(engine, image_path)   # or .deserialize_file
linker   = Wasmtime::Linker.new(engine)
Wasmtime::WASI::P1.add_to_linker_sync(linker)

wasi = Wasmtime::WasiConfig.new
  .set_stdin_string("")                       # never inherit host stdin
  .set_stdout_buffer(stdout, stdout_limit)    # captured + limited output
  .set_stderr_buffer(stderr, stderr_limit)
  .set_argv(["ruby", "/src/main.rb"])
  .set_env(config.env.merge("SB_TOKEN" => token))
  .set_mapped_directory(workdir, "/work", :read_write)

store = Wasmtime::Store.new(engine, wasi_p1_config: wasi,
                            limits: { memory_size: config.memory_size })
store.set_fuel(config.effective_fuel)
instance = linker.instantiate(store, mod)
store.set_epoch_deadline(timeout_ms / epoch_interval_ms + 1)  # right before invoke
instance.invoke("_start")
store.close
```

- **GVL fact (stage 4 Q1)**: `invoke` **holds the GVL** in every guest state.
  Executions on threads serialize; real parallelism comes from `RactorPool`
  (wasmtime `Engine`/`Module` are Ractor-shareable). A stuck guest still cannot
  hang the process — the epoch deadline fires from a native timer.
- Structured result: the guest writes a token-signed JSON envelope to `/work/out.json`
  (read back and verified by the guest before exiting), with a stdout sentinel
  fallback; the host validates schema + token before surfacing anything.
- Limits in use: `consume_fuel` + `set_fuel`, `epoch_interruption` + `set_epoch_deadline`,
  `limits: { memory_size: }` (+ `linear_memory_limit_hit?`), stdout/stderr buffer
  capacities, `store.close` on teardown.

---

## 3. Architecture

```
Configuration (immutable, #with, fingerprint, fuel_ms) ──► Registry (named profiles)
        │
        ▼
   Image (assets/security_box.wasm, repack task) ──► Runtime (Engine cache + compiled Module
        │                                              + content-addressed .cwasm disk cache)
        └────────► EvalRun (shared eval core) ◄────────┘
                       │                       └──► RactorPool (worker Ractors, shareable Engine+Module)
                       ├──► Sandbox (thread-safe wrapper)
                       └──► Pool (bounded :oneshot sandboxes)
                                   │
                                 Result ◄── Envelope (schema + token validation)
```

| Layer | Responsibility |
|---|---|
| `Configuration` | Immutable; Builder DSL, `#with`, `#fingerprint`, `fuel_ms` → `#effective_fuel`. |
| `Registry` | Named profiles (`register`/`resolve`); profiles never mutate. |
| `ModuleCache` | Content-addressed `.cwasm` disk cache (best effort, atomic writes). |
| `Runtime` | `Engine` cache per `epoch_interval_ms`, compiled `Module` per `(engine, image_path)`; `build_shareable` for Ractor pools. |
| `EvalRun` | One `:oneshot` evaluation: WASI config, limits, invoke, trap mapping, envelope read. Shared by `Sandbox` and Ractor workers. |
| `Sandbox` | Thin, thread-safe wrapper over `EvalRun`. |
| `Envelope` | Host-side schema + token validation (forged results → `:sandbox_error`). |
| `Result` | `status`, `value`, `error` (with `backtrace`), `stdout`, `stderr`, `fuel_used`, `duration_ms`, `guest_duration_ms`. |
| `Pool` | Bounded concurrency + sandbox reuse + metrics; serializes on the GVL (documented). |
| `RactorPool` | Real parallelism: worker Ractors sharing one shareable Engine+Module; collector routes results by request id. |

---

## 4. Public API (as delivered)

```ruby
SecurityBox.eval(code, **overrides)                 # one-shot Result
SecurityBox.warmup                                  # pre-build Engine + Module (skips cold compile)

sandbox = SecurityBox::Sandbox.new(config)
sandbox.eval(code, timeout_ms: 500)                 # per-call overrides, profile unchanged

SecurityBox.register(:lean, from: :default) do |c|
  c.fuel 2_000_000_000                              # or c.fuel_ms 200 (rate-based)
  c.timeout_ms 500
end
box = SecurityBox.spawn(:lean)                      # Sandbox from a profile
SecurityBox.spawn(:lean, fuel: 1_000)               # per-call override via #with

pool = SecurityBox.pool(:lean, size: 4)             # bounded concurrency (GVL-serial)
pool.eval(code); pool.metrics; pool.shutdown
rpool = SecurityBox.ractor_pool(:lean, size: 4)     # real parallelism (worker Ractors)
rpool.eval(code); rpool.shutdown

config = SecurityBox::Configuration.build(
  fuel: ..., fuel_ms: ..., timeout_ms:, memory_size:,
  stdout_limit:, stderr_limit:, epoch_interval_ms:, env:
)
config.with(**changes)      # derived copy
config.fingerprint          # stable identity (SHA-256 of the canonical hash)
config.effective_fuel       # fuel_ms-aware (4e6 fuel/ms + ~1e9 boot allowance)
```

Pending API (stage 5 — folder mounts, the M2 leftover):

```ruby
SecurityBox.register(:reader) do |c|
  c.mount    "./data" => "/data"   # read-only by default
  c.mount_rw nil                   # nothing writable outside /work
end
```

---

## 5. Isolation and limits (defense matrix)

| Threat | Defense |
|---|---|
| Infinite loop / CPU | `epoch_interruption` + `set_epoch_deadline` (wall-clock, set right before `invoke`) **and** `consume_fuel` + `set_fuel` (deterministic budget) |
| Memory (bomb) | `limits: { memory_size: }` + `linear_memory_limit_hit?`; guest `NoMemoryError` → `:memory_limit`; module floor 1528 pages (~95.5 MiB) → below it `:sandbox_error` |
| Stack overflow / recursion | rescued in the guest (`SystemStackError` → `:error` envelope) |
| Host disk/RAM exhaustion | `Pool` hard cap on concurrent evals; `store.close` on every teardown |
| Network | WASI p1 has no sockets (`require "socket"` → `LoadError`) |
| Host filesystem | No pre-opened directories: only the sandbox-exclusive `/work` tmpdir (rw). Explicit folder mounts arrive in stage 5 — read-only by default |
| Processes / `system` / backticks / fork | Nonexistent in wasip1; the hardening prelude also neutralizes `system`, `exec`, `Kernel#spawn`, backticks, `IO.popen`, `Process.spawn`, `Kernel#open` (all raise `SecurityError`) |
| stdout flood | `set_stdout_buffer(buf, capacity)` truncates at the configured limit |
| ENV/argv leak | `set_env` only carries allowed variables + the per-eval token; the prelude captures `SB_TOKEN` and scrubs `ENV` before user code runs |
| Forged results | Token-validated envelope (`/work/out.json` + sentinel fallback); strict schema validation; guest verifies its own envelope write; forged results → `:sandbox_error` |

**Primary isolation is WASI + the wasm runtime; the prelude is defense in depth.**
Optional prelude refinement (stage 5 decision): restrict guest `File` write operations
when there is no writable mount — candidate defense-in-depth for the mounts milestone.

---

## 6. Host ↔ guest protocol

### `:oneshot` (delivered, the only mode)

1. Host generates a 128-bit token, creates the sandbox-exclusive tmpdir, writes
   `/work/code.rb`, mounts `/work` read-write, injects the token via `SB_TOKEN`.
2. Fresh instance boots; the prelude captures the token, scrubs `ENV`, neutralizes
   process-spawn APIs, sets `$stdout.sync = true`.
3. The guest evaluates the code with `$stdout` captured, serializes
   `{ok, value, error, backtrace, duration_ms, token}` to `/work/out.json`,
   re-reads it to verify the write (falling back to the stdout sentinel on mismatch),
   and exits 0 — user errors are results, not sandbox failures.
4. The host validates the envelope (schema + token), maps traps to statuses
   (`:interrupt` → `:timeout`, `:out_of_fuel` → `:fuel_exhausted`,
   memory traps/`linear_memory_limit_hit?` → `:memory_limit`, else `:sandbox_error`),
   closes the store, discards the tmpdir.

Zero residual state between executions (one wasm process per eval).

### `:worker` mode — rejected (stage 4)

A long-lived instance amortizing the ~240ms guest boot is infeasible on wasmtime-rb 48
(sync WASI): `invoke` holds the GVL in every guest state (compute *and* blocked reads),
epoch deadlines cannot interrupt a guest sitting in a blocking syscall, and per-request
limits would require cross-thread mutation of a live Store. **Revisit trigger**: a
wasmtime-rb release with GVL-releasing/async WASI or a safe limit re-arm API. The probe
scripts live in `bin/spike_stage4_worker.rb`; full evidence in `docs/plan/stages/stage_4.md`.

---

## 7. Reusable configurations

Delivered:

- `Configuration` is immutable (`Configuration.build` + `#with` derivation); the
  Builder DSL collects only changed values; `env` replaces (not merges).
- `#fingerprint`: SHA-256 of the canonical configuration — equal settings produce
  equal fingerprints; ready for cache identity (used by profile identity/diagnostics;
  artifact keying lands with the ImageBuilder).
- Runtime sharing: engines are memoized per `epoch_interval_ms`, compiled modules per
  `(engine, image_path)`; the `.cwasm` disk cache is content-addressed (image digest +
  `precompile_compatibility_key`), so a new process boots the runtime in ~0.5s
  instead of ~15s.
- Named profiles: `SecurityBox.register(:name, from: :base)`, `SecurityBox.spawn(:name,
  **overrides)`; strict registry (duplicate/unknown names raise `InvalidConfiguration`).

Pending (M3): `ImageBuilder` (ruby version, profile `:full`/`:minimal`, stdlib
allowlist, pure-Ruby gems) and fingerprint-keyed image + compiled-module caches;
build becomes an explicit step (`SecurityBox.build_all!` / rake), with
`SecurityBox::ImageMissing` when a needed image is not built.

---

## 8. File structure (as delivered)

```
lib/security_box.rb                       # eval/warmup/register/spawn/pool/ractor_pool
lib/security_box/configuration.rb         # immutable + Builder DSL + #with + fingerprint + fuel_ms
lib/security_box/registry.rb              # named profiles (register/resolve/profiles/clear!)
lib/security_box/module_cache.rb          # content-addressed .cwasm disk cache
lib/security_box/runtime.rb               # Engine cache + compiled Module + build_shareable
lib/security_box/eval_run.rb              # shared eval core (Sandbox + Ractor workers)
lib/security_box/sandbox.rb               # thread-safe wrapper over EvalRun
lib/security_box/envelope.rb              # host-side envelope schema + token validation
lib/security_box/result.rb                # Result (+ worker_unavailable)
lib/security_box/pool.rb                  # bounded pool of :oneshot sandboxes + metrics
lib/security_box/ractor_pool.rb           # Ractor workers on a shareable Engine+Module
lib/security_box/errors.rb                # Error, ImageMissing, InvalidConfiguration, PoolClosed
lib/security_box/guest/main.rb            # packed entrypoint (_start): envelope + sentinel
lib/security_box/guest/prelude.rb         # hardening: token capture, ENV scrub, API neutralization
lib/security_box/version.rb
lib/security_box/assets/security_box.wasm # packed image (not committed; repack task)
Rakefile                                  # spec, security_box:build_image, verify_image
bin/spike.rb                              # stage-1 spike (Q1–Q9)
bin/spike_stage3*.rb, bin/spike_stage4_worker.rb  # calibration/Ractor/pooling/worker probes
spec/…                                    # unit + integration + escape matrix
```

Not yet present (planned): `image.rb`/`image_builder.rb` (M3), `exe/security_box`
CLI (M5).

Dependencies: `wasmtime` (runtime), `ruby_wasm` (build only), `json` (stdlib).

---

## 9. Roadmap

### Delivered — stages 1–4

| Stage | Focus | Outcome (see stage doc) |
|---|---|---|
| 1 (0.1.0) | Feasibility spike | Core `eval`, all limits, isolation matrix; eval p50 ~257ms; GVL held → serial per process |
| 2 (0.2.0) | Hardening + cold-boot | Token channel + envelope validation, hardening prelude, `.cwasm` disk cache (~15.6s → ~0.56s warm boot) |
| 3 (0.3.0) | Profiles + calibration | `register`/`spawn`, `#fingerprint`, Ractor shareability evidence, memory floor, fuel calibration table, guest backtrace, verified envelope write |
| 4 (0.4.0) | Concurrency | `:worker` mode rejected (GVL evidence), `Pool` + `RactorPool` (~1.9x at 4 workers), `fuel_ms`, `EvalRun` extraction |

### Stage 5 — Folder mounts (next; completes the M2 leftover)

Mount host folders into the sandbox explicitly, read-only by default, so guest code
can safely read a host directory.

- `Configuration` DSL: `c.mount "host/path" => "/data"` (read-only) and `c.mount_rw`
  (opt-in writable, nothing outside `/work` by default).
- `EvalRun`: apply mounts via `set_mapped_directory` after `/work`; host-side
  validation (absolute existing paths, guest-path collisions with `/work`/`/usr`/
  `/src`, duplicates, mount count).
- Behavior probes: read-only mount write failures (`Errno::EROFS` or equivalent),
  coexistence/shadowing with the embedded VFS (stage 1 proved one mount; validate N),
  per-eval cost.
- Decision needed: prelude File-write restriction when no RW mount exists
  (defense in depth).
- Exit criterion: read-only + RW mount matrix green against the real image; mounted
  content read by guest code in specs; security notes documented (a mounted folder's
  content is fully readable by guest code).

### Stage 6 — ImageBuilder and fingerprint-keyed caches (M3)

- `ImageBuilder`: ruby version, `:full`/`:minimal` profile, stdlib allowlist,
  pure-Ruby gems baked into the image.
- Fingerprint-keyed image cache (`~/.cache/security_box/images/<sha>.wasm`) and
  compiled-module cache identity; explicit build step (`rake security_box:build`,
  `SecurityBox.build_all!`); `ImageMissing` when production forbids builds.

### Stage 7 — CLI, docs, threat model (M5)

- CLI `exe/security_box` (`eval`, `build`, `doctor`).
- `docs/SECURITY.md` (threat model, incl. mounts), structured logs, optional
  telemetry, benchmarks in CI (regression guard rail).

### Backlog (revisit triggers)

- Digest micro-optimization (sidecar manifest keyed by size+mtime) — only if
  sub-100ms process boot becomes relevant (warm boot is ~0.56s, dominated by the
  ~555ms image digest).
- `:worker` mode — only when wasmtime-rb ships GVL-releasing/async WASI (stage 4 has
  the probes and evidence).
- `RactorPool` hardening: worker restart after a crash, `Ractor#monitor`/`join`-based
  liveness instead of the pop deadline.
- Pooling allocator — only if a pre-warming pool lands and RSS becomes a concern
  (stage 3 Q3: no benefit for `:oneshot`).
- Investigate: Ractor mode for `Sandbox`/`Pool` beyond the collector-thread contract
  (Ractor-safe paths around `Runtime`/`ModuleCache` class memos).

---

## 10. Tests

Delivered:

- **Escape matrix** (each item yields a `Result`, never breaks the host): `loop {}`,
  `"a" * 10**12`, `system("ls")`, backticks, `IO.popen`, `fork`, `File.write("/etc/passwd")`,
  `Dir["/*"]`, `ENV`, `require "socket"`, `Thread.new`, `exit!`, `at_exit` envelope
  forgery, fake sentinel, giant allocations, deep recursion (backtrace cap), memory
  bombs (`:memory_limit`), `Kernel#open` pipe form.
- **Limits**: every exceeded limit produces the correct status and releases resources
  (`store.close`); epoch precision, fuel exhaustion, memory floor, output truncation.
- **Integrity**: token mismatch → `:sandbox_error`; envelope schema violations;
  verified guest write beats a garbage overwrite.
- **Configs**: `#with` never mutates; equal fingerprints share artifacts; profiles
  never mutate; pool bounding/shutdown; Ractor concurrency + trap recovery.

Stage 5 adds: read-only mount matrix (reads work, writes fail), collision matrix,
`/work` coexistence with N mounts.

---

## 11. Risks and open questions

1. **Boot on the hot path**: ~240ms ruby boot per eval; worker mode rejected. Real
   parallelism only via `RactorPool` (~1.9x at 4 workers on 6 cores); horizontal
   scaling via processes otherwise.
2. **Image size** (110MB wasm + 139MB compiled cache): acceptable for server hosts;
   the `:minimal` profile + stdlib allowlist (stage 6) mitigates for constrained
   environments.
3. **Version fidelity**: the guest Ruby is the ruby.wasm one (4.0), not the host's —
   documented; configurable per profile in stage 6.
4. **Return values**: JSON-only in v1; non-serializable objects surface as `inspect`
   strings. Never introduce host-side `Marshal.load` of guest output.
5. **Observability**: request-id correlation via guest env echoed in the envelope —
   open, belongs with M5 (stage 7).
6. **Mounts widen the trust surface** (stage 5): a mounted folder's content is fully
   readable by guest code; read-only-by-default is the rule, and the threat model
   (stage 7 `docs/SECURITY.md`) must spell out what a mount exposes.
7. **Runtime dependency drift**: wasmtime-rb behavior (GVL, epoch semantics) is
   version-pinned in evidence; re-run the stage 4 probes on any dependency bump.