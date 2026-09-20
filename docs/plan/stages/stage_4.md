# Stage 4 — Concurrency: pools, Ractors, fuel ergonomics

> Living document: we record here **what we want to learn** in this phase and, at the
> end, **what we learned** (with numbers). Original goal: amortize the ~240ms guest
> boot with a long-lived worker instance behind a `Pool`. The worker-mode spike
> (Q1/Q2) proved that infeasible on wasmtime-rb 48, so the phase pivoted to its
> pre-agreed fallback: a bounded `Pool` of `:oneshot` sandboxes, the `RactorPool` for
> real parallelism (on the stage-3 evidence), and `fuel_ms` ergonomics. M3
> (`ImageBuilder`, fingerprint-keyed image/module caches) is explicitly deferred to a
> later stage.

## 1. What we want to understand in this phase

| # | Question | How we will answer |
|---|----------|--------------------|
| Q1 | Does `instance.invoke` hold or release the GVL during wasm execution? (stage-1 Q9 said "holding"; PLAN.md claims release — contradictory, and every worker-mode design depends on the answer) | Spike: run a long `invoke` in one thread; check whether another Ruby thread makes progress meanwhile. Also re-check with epoch/fuel traps firing from a second thread. |
| Q2 | Does the FIFO channel work for a long-lived worker? (`set_stdin_file`/`set_stdout_file`, guest loop reading requests and emitting envelope lines) | Spike: mkfifo pair, host writer/reader threads, N evals through one instance. Fallback: double-buffered files in `/work`. |
| Q3 | What is the amortized per-eval cost of worker mode vs the ~240ms oneshot boot? | Benchmark N sequential evals through one worker vs N oneshot evals; check fuel/epoch per-request reset semantics. |
| Q4 | What happens to the worker on a trap/timeout, and can it be reused? | Expect: the instance is dead after a trap (no epoch yield in wasmtime 48) → worker must be discarded, not reused. Validate statuses and host-side recovery. |
| Q5 | Does worker mode break the "zero residual state" property? (constants/globals/methods defined in eval N leaking into eval N+1) | Probe: define constants/methods/global vars in one eval; check leakage into the next. Design mitigations (fresh anonymous-module binding per request, scrub, `max_evals` discard). |
| Q6 | What is the viable Ractor-pool shape on top of the stage-3 "Plan C" evidence? | Main Ractor builds runtime + `make_shareable(engine/module)`; worker Ractors only create Linker/Store/Instance per eval. What remains Ractor-unsafe in `Runtime`/`ModuleCache` class memos, and can a shareable handle avoid touching them? |

## 2. Scope of this phase

- `bin/spike_stage4_worker.rb` — GVL + FIFO worker spikes (Q1/Q2; negative result).
- `lib/security_box/pool.rb` — bounded pool of `:oneshot` sandboxes: checkout block,
  lazy sandbox creation, metrics. Serializes evals via the GVL (documented); exists
  for resource bounding and API symmetry with `RactorPool`.
- `lib/security_box/ractor_pool.rb` — supported Ractor concurrency (Q6): shareable
  Engine+Module, N worker Ractors, per-eval limits, collector + watchdog.
- `lib/security_box/runtime.rb` — `build_shareable` helper (dedicated, frozen-safe
  Engine+Module for Ractor use).
- `lib/security_box/sandbox.rb` — extracted eval core shared by `Sandbox` and the
  Ractor workers.
- `Configuration#fuel_ms` + Builder support (rate-based fuel ergonomics, backed by the
  stage-3 Q5 calibration table).
- Specs: pool/ractor-pool semantics, `fuel_ms` math, timeout recovery in the pool.
- `docs/plan/stages/stage_4.md` with the measured numbers (this document).

Out of scope (deferred): M3 `ImageBuilder` + fingerprint-keyed image/module caches;
`:worker` mode (infeasible — see Q1/Q2); digest sidecar manifest; CLI (M5).

## 3. Learning journal (log)

### Setup

- Host: Ruby 4.0.5, Linux x86_64, 6 cores / 32GB; `wasmtime` 48.0.1, `ruby_wasm` 2.10.1.
- API verification up front: `WasiConfig#set_stdin_file` / `#set_stdout_file` /
  `#set_stderr_file` exist; `Store#set_epoch_deadline(ticks)` is **trap-only** in this
  binding (no `:yield` behavior), so an epoch deadline that fires kills the instance.
- Measurement pitfalls found on the way (so future stages don't repeat them):
  - The first `Module.from_file` of a day **compiles for ~15s** (before the disk cache
    exists); a "slow" probe that includes boot may just be measuring compilation.
  - **Forked children on this box read `CLOCK_MONOTONIC` skewed** (offset ~-14.6s, rate
    ~1.48x vs the parent). Any spike that sleeps in a `Process.fork` child must journal
    child-side timestamps; three probe runs were invalidated by this before it was found.

### Q1 — GVL behavior (RESOLVED — held, in all guest states)

- **Probe A (compute)**: `Thread.new { invoke }` running a 50M-iteration pure loop
  (2.77s serial); the main thread `sleep(0.3)` and measured when it regained control:
  it woke at **2.77–2.79s**, exactly when `invoke` returned (4 reproductions).
  → **GVL held during wasm execution.** Confirms stage-1 Q9; PLAN.md §2's
  "releases the GVL" claim is wrong for wasmtime-rb 48.
- **Probe C (blocked)**: guest does `gets` #1 (consumes a pre-buffered FIFO line) then
  blocks on `gets` #2 (writer held open, no data). The main thread's post-`sleep(1.0)`
  code **never ran** — the process hung until `SIGKILL` at 90s. An earlier variant
  (D') with a child writing at t=5s woke the main thread exactly at guest exit (5.35s).
  → **GVL held while the guest is blocked on a WASI read.** The worker's idle state is
  indistinguishable from execution to the host.
- **Epoch deadlines do not fire while the guest sits in a blocking syscall** — the
  hung probe had a 60s deadline set before `invoke`; epoch interruption is only
  evaluated at wasm execution checkpoints. A blocked worker cannot be interrupted at
  all (SIGKILL of the process is the only rescue).

### Q2 — FIFO channel (RESOLVED — mechanically works, practically unusable)

- `WasiConfig#set_stdin_file` with a FIFO works at the WASI level: the guest received
  pre-buffered lines correctly in every run that booted.
- But the channel requires host/guest interleaving (host writes request N+1 and reads
  response N while the guest waits), and Q1 shows the host can never run during the
  guest's lifetime — compute or blocked. Previous runs with a parent writer
  deadlocked; `wasmtime` 48's FIFO stdin behavior was additionally fragile
  (identical runs woke at 0.3s / 5.4s / hung).
- Independent of the GVL, per-request limits would require `store.set_fuel` /
  `store.set_epoch_deadline` from another thread **while the store executes** — an
  unsafe cross-thread mutation of a live wasmtime Store (Rust aliasing). Even a
  GVL-releasing future would need wasmtime-rb to expose a safe re-arm API first.
- **Decision: `:worker` mode is infeasible on wasmtime-rb 48 (sync WASI). One invoke
  per request (`:oneshot`) remains the protocol.** The ~240ms boot stays on the hot
  path until a wasmtime-rb release with GVL-releasing/async WASI lands (revisit then).

### Q3 — amortized cost (RESOLVED — moot)

- Moot with Q2: there is no long-lived instance to amortize boot. Concurrency is
  delivered instead by the Ractor pool (Q6): per-eval cost is unchanged (~240ms boot +
  eval), but N workers run in parallel.

### Q4 — worker after trap (RESOLVED — moot)

- Moot with Q2 (no worker). For the record: with a trap-only `set_epoch_deadline`, a
  fired deadline unwinds the invocation; the instance is unusable afterwards, so a
  worker design would have to discard it — consistent with the pool design below.

### Q5 — residual state (RESOLVED — moot)

- Moot with Q2 (each eval still gets a fresh guest process; the "zero residual state"
  property of `:oneshot` is unchanged and remains a selling point).

### Q6 — Ractor pool (RESOLVED — implemented as `RactorPool`)

- Builds directly on stage-3 Q2 "Plan C": the pool builds a dedicated
  `Engine` + `Module`, starts the epoch interval, touches
  `precompile_compatibility_key`, then `Ractor.make_shareable` on both. N worker
  Ractors receive the shareable pair and build only a `Linker` each; per eval they
  create `Store` + `Instance` (~0.2ms), set per-request fuel/epoch deadlines (safe:
  the worker Ractor thread owns its store), and invoke.
- Results come back through the main Ractor's port (`Ractor.main << ...` — the Ruby
  3.4+/4.0 port model; `Ractor.yield`/`#take` no longer exist and a `Queue` is NOT
  Ractor-shareable in 4.0, so a main-side collector thread inside the main Ractor
  drains the port and routes results to per-request Queues by request id). Every
  request terminates (epoch+fuel); a pop deadline converts a dead worker into a
  `:sandbox_error` result instead of a hang.
- Measured through the delivered `RactorPool` (1M–4M-iteration evals, 4–6 workers):

| Workload | workers | serial wall | parallel wall | ratio | RSS end |
|---|---|---|---|---|---|
| 1M-iteration evals | 4 | 1259 ms | 672 ms | 0.53 | 56 MB |
| 2M-iteration evals | 4 | 1463 ms | 781 ms | 0.53 | 57 MB |
| 4M-iteration evals | 4 | 1874 ms | 968 ms | 0.52 | 57 MB |
| 2M-iteration evals | 6 | 2188 ms | 1170 ms | 0.53 | 58 MB |

  → ≈1.9x wall-time speedup, stable across workload sizes and worker counts, all
  statuses `:ok`, no crashes. (Stage-3's 0.28 ratio ran 3 evals per Ractor back to
  back — longer runs amortize boot and startup contention further; its 111MB RSS
  also included that multi-eval measurement shape.)

## 4. Implementation delivered

```
docs/plan/stages/stage_4.md                # this document
bin/spike_stage4_worker.rb                 # Q1/Q2 probes (GVL, FIFO stdin, epoch behavior)
lib/security_box/eval_run.rb               # shared eval core (Sandbox + RactorPool workers)
lib/security_box/sandbox.rb                # thin wrapper over EvalRun (thread-safe linker init)
lib/security_box/pool.rb                   # bounded pool of :oneshot sandboxes + metrics
lib/security_box/ractor_pool.rb            # Ractor workers on a shareable Engine+Module
lib/security_box/runtime.rb                # Runtime.build_shareable (dedicated frozen-safe pair)
lib/security_box/result.rb                 # Result.worker_unavailable factory
lib/security_box/errors.rb                 # PoolClosed
lib/security_box/configuration.rb          # fuel_ms + effective_fuel + conflict rules
lib/security_box.rb                        # SecurityBox.pool / SecurityBox.ractor_pool
spec/security_box/pool_spec.rb             # bounding, reuse, shutdown, overrides
spec/security_box/ractor_pool_spec.rb      # Ractor evals, concurrency, trap recovery
spec/security_box/configuration_spec.rb    # +11 fuel_ms examples
README.md, CHANGELOG.md                    # 0.4.0
```

No guest changes: the worker protocol never shipped, so no image repack was needed.

## 5. Decisions made in this phase

1. **`:worker` mode rejected on this runtime** (Q1/Q2 evidence): `invoke` holds the
   GVL in every guest state (computing *and* blocked on WASI reads), epoch deadlines
   cannot interrupt a guest sitting in a blocking syscall, and per-request limits
   would require cross-thread mutation of a live Store. One invoke per request stays
   the protocol; revisit only when wasmtime-rb ships GVL-releasing/async WASI or a
   safe limit re-arm API.
2. **Two pools, two honest contracts**: `Pool` bounds concurrency and reuses sandbox
   objects but serializes on the GVL (documented in its docs and README);
   `RactorPool` is the parallelism story (~1.9x at 4 workers on 6 cores).
3. **RactorPool on a dedicated shareable runtime pair** (`Runtime.build_shareable`),
   NOT the memoized ones — `make_shareable` freezes, and freezing shared artifacts
   would leak into every Sandbox. Cost: one module deserialize per pool (~0.5s via
   the disk cache).
4. **Result routing via the main Ractor port + collector thread**: Ruby 3.4+/4.0
   removed `Ractor.yield`/`#take` and `Queue` is not Ractor-shareable in 4.0, so
   workers `Ractor.main << result` and one main-side thread routes by request id.
   The pool's collector must be the only `Ractor.receive` caller in the process
   (documented); a pop deadline turns a dead worker into `:sandbox_error`.
5. **`fuel_ms` precedence, not errors, at the value level**: `effective_fuel` uses
   `fuel_ms` when set; conflicts are rejected only where user intent is explicit
   (builder DSL, `#with` overrides, registry derivation), because `#with` rebuilds
   from `to_h` and cannot distinguish "default" from "explicitly equal to default".
   `with(fuel_ms: nil, fuel: x)` is the documented escape hatch.
6. **Spike-hygiene lessons recorded in the journal**: cold module compilation (~15s)
   masquerades as slow probes; forked children on this host read `CLOCK_MONOTONIC`
   skewed (~-14.6s offset, ~1.48x rate) — child-side timestamps are mandatory in
   forking probes.
7. **Sandbox is thread-safe** (mutex-guarded lazy linker; shared Engine/Module are
   thread-safe), enabling `Pool` to hand the same sandbox objects to several threads
   sequentially.

## 6. Pending items for Stage 5

- [ ] M3: `ImageBuilder` (version, profile, stdlib components, gems allowlist) +
      fingerprint-keyed image and compiled-module caches.
- [ ] Digest micro-optimization (sidecar manifest keyed by size+mtime) if sub-100ms
      process boot ever matters (unchanged from stage 2).
- [ ] M5: CLI (`eval`, `build`, `doctor`), docs, `docs/SECURITY.md` threat model.
- [ ] Revisit `:worker` mode when wasmtime-rb offers GVL-releasing or async WASI
      (stage-4 Q1/Q2 has the full evidence and the probe scripts to re-run).
- [ ] RactorPool hardening ideas (only if needed): worker restart after a crash,
      `Ractor#monitor`/`join`-based liveness instead of the pop deadline.
