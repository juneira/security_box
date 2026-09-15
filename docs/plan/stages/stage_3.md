# Stage 3 — Profiles, parallelism, and resource calibration

> Living document: we record here **what we want to learn** in this phase and, at the end,
> **what we learned** (with numbers). Goal of this phase: the named-profile public API
> (`register`/`spawn` + configuration fingerprint), the two guest-protocol polish items
> (backtrace in the error envelope, guest-side envelope-write verification), and the
> deferred investigations (Ractor parallelism, pooling allocator, minimum viable
> `memory_size`, fuel calibration per workload type).

## 1. What we want to understand in this phase

| # | Question | How we will answer |
|---|----------|--------------------|
| Q1 | How do named profiles + `register`/`spawn` work, and what keys the shared runtime? | Builder DSL per PLAN.md §4 (`register(:name, from: :base) { \|c\| c.fuel 100 }`), `spawn(:name, **overrides)` returning a `Sandbox`; `Configuration#fingerprint` (SHA-256 of the normalized `to_h`); `Runtime` memoization keyed by fingerprint instead of `engine.object_id`. |
| Q2 | Does Ractor enable real parallelism despite the GVL-holding `invoke` (stage-1 Q9)? | Spike: N Ractors sharing Engine+Module, wall vs sum-of-times ratio; check whether wasmtime objects are Ractor-shareable. |
| Q3 | Does the pooling allocator help? | Benchmark `Engine.new(allocation_strategy:)` vs default: `Store.new`+instantiate p50, RSS footprint with live stores. |
| Q4 | What is the minimum viable `memory_size` for the ruby.wasm boot? | Probe boot with decreasing `memory_size` (512→64MB) running `require "json"` + allocation; propose a new default with margin. |
| Q5 | What are the fuel rates per workload type? | Measure fuel/s for: pure loop (stage-1 baseline ~8.4e9), method calls, string ops, array ops, JSON serialize, output; publish a calibration table. |
| Q6 | Can the error envelope carry a backtrace? | Guest: `e.backtrace` capped (~20 frames) in the envelope; host: optional `backtrace` array in `Envelope` validation, surfaced via `Result#error`. |
| Q7 | Can the guest verify the envelope write succeeded? | Guest: verify `/work/out.json` after writing (re-read and compare) before exiting; fall back to the stdout sentinel on mismatch. |

## 2. Scope of this phase

- `lib/security_box/registry.rb` — named profiles: `SecurityBox.register` / `SecurityBox.spawn`.
- `lib/security_box/configuration.rb` — builder DSL + `#fingerprint`.
- `lib/security_box/runtime.rb` — memoization keyed by configuration fingerprint.
- `lib/security_box/guest/main.rb` — backtrace in the error envelope + envelope-write
  verification (image repack required).
- `lib/security_box/envelope.rb`, `lib/security_box/result.rb` — accept/surface the
  guest backtrace.
- Spike measurements (Q4/Q5/Q2/Q3) and the numbers recorded in this document.
- Specs: profiles/fingerprint unit matrix; backtrace + write-verification integration
  tests.
- `docs/plan/stages/stage_3.md` with the measured numbers (this document).

Out of scope (deferred to Stage 4+): `Pool` with hot instances (M4); image builder and
`.wasm` disk cache keyed by fingerprint (M3); CLI; digest micro-optimization (sidecar
manifest) — revisited only if sub-100ms process boot becomes relevant; `:worker` mode.

## 3. Learning journal (log)

### Setup

- Host: Ruby 4.0.5, Linux x86_64, 6 cores / 32GB; `wasmtime` 48.0.1, `ruby_wasm` 2.10.1.
- Image repacked (guest changes: backtrace + verified write). Numbers below measured
  against the repacked image unless noted.

### Q1 — named profiles and fingerprint (RESOLVED)

- API delivered exactly as planned:
  - `SecurityBox.register(:name, from: :base) { |c| c.fuel 5_000_000 }` — the builder
    collects only the changed values; unregistered names, duplicate registrations and
    unknown `from:` raise `SecurityBox::InvalidConfiguration`. String names are
    normalized to Symbols.
  - `SecurityBox.spawn(:name, **overrides)` — builds a `Sandbox` from a profile with
    per-call overrides derived via `#with` (the profile itself never mutates).
    `spawn(Configuration)` and `spawn()` (defaults) are also accepted.
  - `c.env` **replaces** the environment (it does not merge with the base profile) —
    merging would surprise ("why is my token env still there?").
- `Configuration#fingerprint`: SHA-256 of the canonical hash (env key-sorted). Equal
  settings → equal fingerprint regardless of how the object was built; any `#with`
  change → different fingerprint. Verified by spec.
- **Finding — Runtime keyed by fingerprint is a non-goal today.** The hypothesis
  "fingerprint should key the Runtime memo" dissolved on inspection: identical configs
  already share the runtime artifacts (engines are memoized per `epoch_interval_ms`,
  modules per `(engine, image_path)`), and fuel/timeout/memory are *per-store*, so two
  configs differing only in limits share everything already. The fingerprint's real use
  is later: keyed image builds and compiled-module cache identity (M3) and profile
  identity/diagnostics.

### Q2 — Ractor parallelism (RESOLVED — yes, with a shared runtime)

- Plan A: `Ractor.make_shareable(engine)` and `Ractor.make_shareable(module)` **both
  succeed**. Requirement: initialize everything before freezing — engine →
  `start_epoch_interval` → touch `precompile_compatibility_key` → `make_shareable`.
- Plan B (N Ractors × private runtime, module deserialized from the stage-2 disk cache
  per Ractor; 3 evals of a 2M-iteration loop each; all `:ok`):

| n | wall | serial sum | ratio | RSS end |
|---|---|---|---|---|
| 2 | 861 ms | 1524 ms | 0.56 | 140 MB |
| 4 | 1117 ms | 4004 ms | 0.28 | 210 MB |

- Plan C (one Engine+Module made shareable; Ractors pay only `Store.new` +
  `instantiate` + `invoke`): **same parallelism, lower footprint**:

| n | wall | serial sum | ratio | RSS end |
|---|---|---|---|---|
| 2 | 843 ms | 1506 ms | 0.56 | 111 MB |
| 4 | 947 ms | 3378 ms | 0.28 | 111 MB |

- 4 Ractors on 6 cores: ≈3.6x speedup, zero crashes; epoch and fuel deadlines still
  fire per-store from within Ractors.
- Library blockers for adoption today: class-level memos (`Runtime` engines/modules +
  `Mutex`, `ModuleCache` keys) raise `Ractor::IsolationError` from non-main Ractors.
  The viable shape is: main Ractor builds + shareables the runtime, worker Ractors
  receive the shared Engine/Module and create Store/Instance per eval (Linker per
  Ractor).
- Decision: document the pattern; a supported Ractor mode (pool of worker Ractors) is a
  stage-4 (M4) implementation backed by this evidence.

### Q3 — pooling allocator (RESOLVED — not adopted)

- API (discovered): `Wasmtime::Engine.new(allocation_strategy: Wasmtime::PoolingAllocationConfig)`
  (also accepts `:pooling` for defaults). Tuned config used: `total_memories/stacks/
  tables/instances = 16`, `max_memory_size = 512MB`.
- Same `precompile_compatibility_key` as the default engine → the module disk cache is
  shared (no 15s recompile per strategy).
- Results (30 warm iterations, 4 live stores):

| Metric | default | pooling |
|---|---|---|
| `Store.new`+`instantiate` p50 | 0.112 ms | 0.102 ms |
| `invoke("_start")` p50 (boot) | 233.6 ms | 251.1 ms |
| RSS (1 live store) | 69 MB | 69 MB |
| RSS (4 live stores) | 69 MB | 70 MB |

- Conclusion: nothing to gain for `:oneshot`. Instantiation is already ~0.1ms and
  linear memories are lazily committed; RSS is dominated by the compiled module, not by
  memory reservations. **Key insight: the ~240ms per eval is ruby boot — amortization
  must target boot (worker mode / pool of pre-warmed instances), not allocation.**
  Revisit pooling only if a stage-4 pool pre-boots instances and RSS becomes a concern.

### Q4 — minimum viable memory_size (RESOLVED)

- **Hard floor: 1528 pages (~95.5 MiB)** — the packed module declares this minimum;
  below it, `instantiate` fails before the guest boots (`memory minimum size of 1528
  pages exceeds memory limits`).
- Behavior ladder (basic ops = `require "json"` + `JSON.generate`; buffers = 1MB of
  string appends):

| memory_size | behavior |
|---|---|
| < 95.5 MiB | `Wasmtime::Error` at instantiate → now mapped to a `:sandbox_error` Result with a `security_box:` note on stderr (never an exception escaping `#eval`) |
| 95.5 MiB (exact floor) | guest aborts at boot (`[BUG] Out of memory`) → `:memory_limit` |
| 112 MB | boots; basic ops OK; 1MB buffers hit the wasm limit → `:memory_limit` |
| 128 MB | basic ops OK; 1MB buffers make the Ruby interpreter raise `NoMemoryError` **before** the wasm limit → previously reported as `:error` (footgun), now mapped to `:memory_limit` |
| 136–144 MB | 1MB-buffer workloads pass |
| default 512 MB | unchanged — comfortable headroom for real workloads |

- Decision: keep the 512MB default; document the floor (absolute 1528 pages; practical
  minimum ~128MB for small workloads, 144MB+ for a few MB of allocations).

### Q5 — fuel calibration (RESOLVED)

- **Epoch traps restore fuel to the last checkpoint.** After a `:timeout`, the store
  reports almost exactly the boot-time fuel (913.7M) even though the loop truly burned
  >20e9 in 3s — the epoch-interruption mechanism rolls back pending fuel so execution
  can be retried. Consequences:
  - `fuel_used` is truthful on completion, on fuel exhaustion (== budget exactly) and
    on memory traps, but **meaningless after `:timeout`** → the library now reports
    `fuel_used: nil` for `:timeout` (spec covers it).
- True pure-loop rate confirmed via the exhaustion path: 20e9 budget exhausted in
  2.38s → **8.4e9 fuel/s** (matches stage 1's baseline).
- Boot baseline: **~9.1e8 fuel** (~276ms) for boot + empty eval + envelope. Budget for
  boot even on trivial evals.
- Calibration table (net fuel per operation, boot baseline subtracted):

| Workload | fuel/op | rate (fuel/s) |
|---|---|---|
| integer loop (`i += 1`) | ~473 | 7.3e9 |
| method call | ~1193 | 5.1e9 |
| array push | ~941 | 4.8e9 |
| hash insert | ~1911 | 4.2e9 |
| string `<<` (mutating) | ~2516 | 3.9e9 |
| string concat (new string) | ~4597 | 4.1e9 |
| `JSON.parse` (small) | ~10,403 | 4.3e9 |
| `JSON.generate` (small) | ~38,454 | 3.6e9 |
| `print` (10 bytes) | ~54,640 | 3.2e9 |

- Guidance for profile authors: budget ≈ expected wall time × **4–8e9 fuel/s** for
  compute workloads (tight VM loops burn up to 8.4e9/s); add ~1e9 per eval for boot.
  The epoch timeout remains the mandatory wall-clock backstop.
- Interaction with `timeout_ms`: the deadline is set immediately before the `invoke`,
  and the guest boot alone takes ~240ms — so `timeout_ms` below ~300ms cannot complete
  even a trivial eval (verified: `timeout_ms: 100` on `1 + 1` → `:timeout` during
  boot). Profiles should treat ~500ms as a practical floor.

### Q6 — backtrace in the error envelope (RESOLVED)

- Guest: the error envelope now carries `"backtrace"` — user frames only
  (`main.rb`/`prelude.rb` frames stripped), capped at 20 frames so deep recursion
  cannot flood the channel. Verified shape: `["sandbox:1:in 'Object#boom'",
  "sandbox:1:in '<main>'"]` — sandbox-internal locations only, no host paths.
- Host: `Envelope` accepts an optional array-of-strings backtrace on error envelopes;
  any other shape invalidates the envelope (→ `:sandbox_error`). Missing backtrace is
  still valid (backwards compatible). Surfaced through `Result#error` unchanged.
- Verified end-to-end against the real image (incl. the deep-recursion cap).

### Q7 — guest-side envelope-write verification (RESOLVED)

- Guest `emit` now: (1) `File.write` the envelope, (2) read it back and compare with
  the exact JSON, (3) on mismatch or any failure, fall back to the stdout sentinel.
- Verified end-to-end: user code overwriting `/work/out.json` with garbage during eval
  still yields the correct trusted result (the verified write wins).
- Note: the mismatch branch cannot be triggered from inside the guest's in-memory VFS;
  the read-back is defense in depth against silent truncation/partial writes (e.g. a
  future host-side pipe or disk-backed `/work`).

## 4. Implementation delivered

```
docs/plan/stages/stage_3.md              # this document
lib/security_box/configuration.rb        # Builder DSL + #fingerprint + canonical
lib/security_box/registry.rb             # named profiles (register/resolve/profiles/clear!)
lib/security_box.rb                      # SecurityBox.register / SecurityBox.spawn
lib/security_box/module_cache.rb         # cache_path made public (spikes need the path)
lib/security_box/guest/main.rb           # backtrace + read-back-verified envelope write
lib/security_box/envelope.rb             # optional backtrace validation
lib/security_box/sandbox.rb              # instantiate rescue, NoMemoryError → :memory_limit,
                                         #   fuel_used nil on :timeout
bin/spike_stage3.rb                      # Q4/Q5 measurements (memory floor, fuel table)
bin/spike_stage3_ractor.rb               # Q2 (plans A/B/C)
bin/spike_stage3_pooling.rb              # Q3
spec/security_box/registry_spec.rb       # 17 examples (profiles + spawn matrix)
spec/security_box/configuration_spec.rb  # +4 examples (fingerprint)
spec/security_box/envelope_spec.rb       # +4 examples (backtrace schema)
spec/security_box/sandbox_spec.rb        # +7 examples (backtrace, NoMemoryError, floor,
                                         #   timeout fuel, stale out.json overwrite)
README.md, CHANGELOG.md                  # 0.3.0
```

## 5. Decisions made in this phase

1. **Builder DSL** per PLAN.md §4: `c.fuel 1_000` (no `=`); only changed values are
   collected; `env` replaces the base environment instead of merging.
2. **Strict registry**: duplicate names and unknown `from:`/lookups raise
   `InvalidConfiguration`; profiles are immutable once registered; `Registry.clear!`
   exists for tests.
3. **`spawn` polymorphism**: registered name, `Configuration` instance, or nothing
   (defaults). Overrides always derive via `#with` — profiles never mutate.
4. **Runtime keying unchanged**: engines per `epoch_interval_ms`, modules per
   `(engine, image_path)`; the configuration fingerprint is reserved for M3 caches and
   profile identity (no sharing gain today).
5. **`fuel_used: nil` on `:timeout`** — epoch traps restore fuel to the checkpoint;
   reporting the restored value would understate consumption by orders of magnitude.
   Truthful on completion/exhaustion/memory traps.
6. **Guest `NoMemoryError` → `:memory_limit`**: inside the sandbox, interpreter OOM
   means the store limit (the guest cannot otherwise exhaust host memory); reporting it
   as a user error was a footgun at 128MB-class limits.
7. **Below the module floor → `:sandbox_error` Result** (with a `security_box:` stderr
   note) instead of raising: preserves the "always a Result" contract; the alternative
   (raising `InvalidConfiguration`) was rejected. Floor documented (1528 pages ≈ 95.5
   MiB; practical minimum ~128–144MB).
8. **Backtrace**: guest frames only, capped at 20, optional schema field validated
   host-side (array of strings) — a malformed backtrace invalidates the envelope.
9. **Ractor**: pattern documented (shared Engine+Module via `make_shareable`); a
   supported Ractor pool is deferred to M4 with this evidence.
10. **Pooling allocator: not adopted** — no latency or RSS benefit for `:oneshot`;
    revisit only for a pre-warming pool in M4.

## 6. Pending items for Stage 4

- [ ] `Pool` (M4): hot instances / worker mode — amortize the ~240ms **boot** (Q3:
      instantiation is already 0.1ms, allocation is not the cost).
- [ ] Ractor pool (M4): implement the Plan C pattern as a supported concurrency mode;
      requires Ractor-safe paths around `Runtime`/`ModuleCache` class memos.
- [ ] M3: `ImageBuilder` (version, profile, stdlib components, gems allowlist) +
      fingerprint-keyed image and compiled-module caches.
- [ ] Fuel ergonomics: consider a rate-based option (e.g. `fuel_ms:`) backed by the
      Q5 calibration table.
- [ ] Digest micro-optimization (sidecar manifest keyed by size+mtime) if sub-100ms
      process boot ever matters (unchanged from stage 2).
- [ ] `:worker` mode spike (FIFO channel) if the pool still leaves boot cost on the
      hot path.
