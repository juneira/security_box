# Stage 2 — Hardening and cold-boot performance

> Living document: we record here **what we want to learn** in this phase and, at the end,
> **what we learned** (with numbers). Goal of this phase: raise the integrity of the
> result channel against a forging guest, add the hardening prelude, and eliminate the
> ~15s cold module compilation with a disk cache.

## 1. What we want to understand in this phase

| # | Question | How we will answer |
|---|----------|--------------------|
| Q1 | Does the compiled-module disk cache eliminate the ~15s cold compilation? | `Module#serialize` + `Module.deserialize_file`, keyed by image content digest + `engine.precompile_compatibility_key`. Measure compile vs deserialize, serialization cost, digest cost. |
| Q2 | Can the result channel resist a forging guest? | Per-eval random token (ENV, read and erased by the prelude) embedded in the envelope and the sentinel line; strict host-side schema validation; sentinel count check. Try the stage-1 forging scenarios (`at_exit` overwrite, fake sentinel). |
| Q3 | What must the hardening prelude neutralize, and what survives? | Probe `system`, backticks/`%x`, `IO.popen`, `Process.spawn`, `Kernel#open` (pipe form), `ENV` — before and after the prelude. |
| Q4 | What does the added defense cost? | Warm-boot latency, SHA-256 digest cost (once per process), prelude overhead. |

## 2. Scope of this phase

- `lib/security_box/module_cache.rb` — content-addressed `.cwasm` cache under
  `~/.cache/security_box/modules/` (override: `SECURITY_BOX_CACHE_DIR`; best effort —
  silently skipped when unavailable), atomic writes (tmp + rename), corruption → recompile.
- `lib/security_box/runtime.rb` — consult the cache before compiling.
- `lib/security_box/guest/prelude.rb` — token capture + ENV scrub, neutralization of
  process-spawn APIs, `$stdout.sync = true`. Packed into the image next to `main.rb`.
- `lib/security_box/guest/main.rb` — embed the token in the envelope and the sentinel line.
- `lib/security_box/sandbox.rb` — per-eval token generation, envelope schema validation
  (`lib/security_box/envelope.rb`), host-side sentinel parsing with count check.
- Specs: envelope/module-cache unit matrix + forging/neutralization integration tests.
- `docs/plan/stages/stage_2.md` with the measured numbers (this document).

Out of scope (deferred to Stage 3+): named profiles/`register`/`spawn` API and configuration
fingerprint; minimum viable `memory_size` investigation; Ractor parallelism; pooling
allocator benchmark; fuel calibration per workload.

## 3. Learning journal (log)

### Setup

- Host: Ruby 4.0.5, Linux x86_64; `wasmtime` 48.0.1, `ruby_wasm` 2.10.1.
- Image repacked (guest changes: `main.rb` + new `prelude.rb`).
- API verification: `Module#serialize` → serialized `String`;
  `Module.deserialize_file(engine, path)` — **engine first** (reversed order raises
  `TypeError`); `Engine#precompile_compatibility_key` → hex `String`. An empty module
  serializes to ~9KB (engine metadata is included even for trivial modules).

### Q1 — compiled-module disk cache (RESOLVED)

| Step | p50 |
|---|---|
| `Module.from_file` (cold compile, 110MB image) | 15,612 ms |
| `cache_key` (SHA-256 of image + compat key) | 555 ms (once per process, memoized) |
| `store` (`Module#serialize` + atomic write) | 175 ms |
| `load_module` (`deserialize_file`, warm process) | **1.1 ms** |
| Fresh-process `warmup` (digest + deserialize) | 556 ms |
| `.cwasm` cache file size | 139 MB |

- Net effect: a new process boots the runtime in **~0.56s instead of ~15.6s (28x)**;
  the in-process memoized module is reused across all evals as before.
- Design that made it safe: the cache key is **content-addressed** (image digest +
  `precompile_compatibility_key`), so repacking the image can never collide with stale
  cache entries and a stored module is only reused when the engine is compatible.
- Writes are atomic (tmp + `File.rename`), so concurrent processes never observe a
  partial file. Corrupted/unavailable cache degrades to a normal compile and self-heals
  on the next store.
- Note: the warm path is now dominated by the digest (~555ms). A sidecar manifest keyed
  by (size, mtime) could cut it further if sub-100ms boot ever matters (deferred).

### Q2 — result channel integrity (RESOLVED)

- Protocol: the host generates a 128-bit random token per eval (`SecureRandom.hex(16)`)
  and passes it via WASI env (`SB_TOKEN`). The prelude captures it and scrubs ENV before
  user code runs; afterwards the token exists only in the guest protocol's local scope.
  Both the `/work/out.json` envelope and the sentinel line (`SENTINEL:token:json`) embed it.
- Host-side validation (`Envelope`): JSON parses; `ok` is boolean; token matches;
  `value` key present when ok; `error{class,message}` strings when not; `duration_ms`
  numeric when present. Sentinel fallback additionally enforces **exactly one**
  sentinel line (count check). Any violation → the envelope is discarded →
  `:sandbox_error` (for a successful invoke).
- Forging attempts (integration tests, real image):
  - `at_exit` overwriting `out.json` without the token → `:sandbox_error` ✅
  - `at_exit` overwrite carrying a guessed token → `:sandbox_error` ✅
  - fake stdout sentinel while a valid envelope exists → ignored ✅
- Sentinel fallback re-validated end-to-end (no `/work` mounted, code via argv):
  valid token envelope parsed; wrong-token envelope rejected. ✅
- **Residual risk (accepted, documented)**: the token lives in guest memory during the
  run; a sufficiently determined guest could attempt to locate it in-process. The channel
  is hardened against the practical stage-1 forgery paths (`at_exit` overwrite, stdout
  sentinel) — it is defense in depth, not a cryptographic guarantee.

### Q3 — hardening prelude (RESOLVED)

- `guest/prelude.rb` runs before user code: capture token → scrub ENV → neutralize
  process-spawn APIs → `$stdout.sync = true`.
- Neutralized (all raise `SecurityError` now): `system`, `exec`, `Kernel#spawn`,
  backticks/`%x` (same `Kernel#\`` method), `IO.popen`, `Process.spawn`, `Kernel#open`.
  Before the prelude, `system("ls")` returned `true` while running nothing — a misleading
  stub that could hide failed side effects from guest code.
- `Kernel#open` is disabled **entirely** (its pipe form executes processes); plain file
  APIs stay available (`File.read`/`File.write` covered by specs).
- Nothing else broke: `require "json"` works, plain files work, guest boot is unchanged.

### Q4 — cost of the defense (MEASURED)

| Metric | Stage 1 | Stage 2 |
|---|---|---|
| `eval` p50 (warm runtime) | 257 ms | 266 ms (prelude + token ≈ noise) |
| Cold boot (first process) | ~15.6 s | ~15.8 s (adds serialize/store) |
| Warm boot (new process) | ~15.6 s | **~0.56 s** (disk cache) |
| RSpec suite | 21 examples, ~21 s | 75 examples, ~26 s |

## 4. Implementation delivered

```
docs/plan/stages/stage_2.md              # this document
lib/security_box/module_cache.rb         # content-addressed .cwasm disk cache (best effort)
lib/security_box/runtime.rb              # consults ModuleCache before compiling
lib/security_box/envelope.rb             # host-side envelope schema + token validation
lib/security_box/sandbox.rb              # per-eval token, env injection, validated envelope
lib/security_box/guest/prelude.rb        # token capture + ENV scrub + API neutralization
lib/security_box/guest/main.rb           # token in envelope + sentinel, loads prelude
spec/security_box/envelope_spec.rb       # 21 examples (validation matrix)
spec/security_box/module_cache_spec.rb   # 8 examples (round-trip, corruption, disabled)
spec/security_box/runtime_spec.rb        # 1 example (fresh engine serves from cache)
spec/security_box/sandbox_spec.rb        # +13 examples (prelude, forging, integrity)
```

## 5. Decisions made in this phase

1. **Cache key**: SHA-256 of the image **content** + `precompile_compatibility_key` —
   content-addressed beats mtime heuristics (repacks and engine changes cannot collide).
2. **Cache behavior**: best effort, never fatal — miss/corruption/unwritable dir falls
   back to compiling; atomic writes (tmp + rename); `SECURITY_BOX_CACHE_DIR` overrides
   the default `~/.cache/security_box`; no HOME → cache disabled.
3. **Token**: 128-bit hex per eval, delivered via `SB_TOKEN` ENV, validated host-side;
   prelude scrubs ENV right after capture. Accepted residual risk: token is present in
   guest memory during execution.
4. **Neutralization semantics**: denied APIs raise `SecurityError` (a clear, visible
   denial) instead of keeping the misleading WASI stubs (`system` → `true`).
   `Kernel#open` is fully disabled; `File.open` is the sanctioned path.
5. **Envelope trust**: strict schema validation; a result that fails any check is never
   surfaced as a value — the execution becomes `:sandbox_error`.
6. **Sentinel format**: `__SECURITY_BOX_RESULT__:<token>:<json>` with a single-line
   count check (kept compatible with the /work-less fallback path).

## 6. Pending items for Stage 3

- [ ] Named profiles (`SecurityBox.register`/`spawn`) and configuration fingerprint
      (deferred from stage 1 §6).
- [ ] Optional digest micro-optimization (sidecar manifest keyed by size+mtime) if
      sub-100ms process boot becomes relevant.
- [ ] Investigate: minimum viable `memory_size` for the ruby.wasm boot; fuel rates per
      workload type (deferred from stage 1 §6).
- [ ] Investigate: Ractor for real parallelism; pooling allocator benchmark (deferred
      from stage 1 §6).
- [ ] Consider backtrace capture in the error envelope (PLAN.md mentions `backtrace` in
      `Result#error`).
- [ ] Consider a guest-side verification that the envelope write actually succeeded
      before exiting (currently best effort with the sentinel fallback).
