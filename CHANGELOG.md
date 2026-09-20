# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-09-15

### Added

- `SecurityBox::Pool` (`SecurityBox.pool`): a bounded pool of `:oneshot` sandboxes —
  hard cap on concurrent evals (`size:`), sandbox reuse, `checkout` block and metrics
  (`created`/`evals`/`total_ms`/`avg_ms`). Evals serialize on the GVL (documented).
- `SecurityBox::RactorPool` (`SecurityBox.ractor_pool`): real parallelism — worker
  Ractors sharing one Ractor-shareable Engine + compiled Module (stage-3 "Plan C").
  Measured ≈0.52–0.53 parallel/serial wall ratio at 4 workers on 6 cores (~1.9x),
  RSS ≈57MB; per-call overrides, statuses and trap recovery behave like
  `Sandbox#eval`; a dead worker degrades to a `:sandbox_error` Result instead of a
  hang.
- `Configuration#fuel_ms`: rate-based fuel budgeting (~4e6 fuel/ms from the stage-3
  calibration table + ~1e9 boot allowance), exposed via `Configuration#effective_fuel`
  and usable per call. `fuel` and `fuel_ms` are mutually exclusive in the builder DSL
  and in `#with`; switch back with `with(fuel_ms: nil, fuel: ...)`.
- `docs/plan/stages/stage_4.md` with the worker-mode feasibility investigation.

### Changed

- The eval core was extracted from `Sandbox` into `SecurityBox::EvalRun` (shared by
  `Sandbox` and `RactorPool` workers); `Sandbox` is now a thin, thread-safe wrapper.
- README: the "Ractor note" roadmap item is delivered; concurrency guidance rewritten
  around `Pool`/`RactorPool`.

### Investigation (negative result, documented)

- `:worker` mode (long-lived instance amortizing the ~240ms boot) is infeasible on
  wasmtime-rb 48 (sync WASI): `invoke` holds the GVL during compute *and* while the
  guest is blocked on a WASI read; epoch deadlines never fire inside a blocking
  syscall; and per-request limits would require mutating a live Store from another
  thread (unsafe). Evidence and probes in `docs/plan/stages/stage_4.md` and
  `bin/spike_stage4_worker.rb`.

## [0.3.0] - 2026-09-14

### Added

- Named, reusable profiles: `SecurityBox.register(:name, from: :base) { |c| c.fuel 100 }`
  and `SecurityBox.spawn(:name, **overrides)` (a `Configuration` or the defaults also
  work). Profiles are immutable; duplicate/unknown names raise
  `SecurityBox::InvalidConfiguration`.
- `SecurityBox::Configuration#fingerprint`: a stable identity for equal settings
  (SHA-256 of the canonical configuration), ready for artifact caches.
- Guest error envelopes now carry a `backtrace`: user frames only, capped at 20,
  sandbox-internal locations (no host paths). Surfaced via `Result#error["backtrace"]`;
  malformed backtraces invalidate the envelope (`:sandbox_error`).
- `Result#fuel_used` is now `nil` for `:timeout`: epoch traps restore fuel to the last
  checkpoint, so the restored value understated consumption by orders of magnitude.
  (Truthful on completion, fuel exhaustion and memory-limit traps.)

### Changed

- A guest `NoMemoryError` (interpreter OOM against the store limit) is reported as
  `:memory_limit` instead of `:error`.
- A `memory_size` below the image's declared minimum (1528 pages ≈ 95.5 MiB) now
  returns a `:sandbox_error` Result with a `security_box:` note on stderr instead of
  raising `Wasmtime::Error` out of `#eval`.
- The sandbox image must be repacked (`rake security_box:build_image`) when
  upgrading: the guest entrypoint protocol changed.

## [0.2.0] - 2026-09-14

### Added

- Compiled-module disk cache (`~/.cache/security_box/modules`, override with
  `SECURITY_BOX_CACHE_DIR`): new processes boot the runtime in ~0.5s instead
  of ~15s by deserializing the compiled artifact instead of recompiling.
  Best effort — misses, corruption or an unwritable directory fall back to a
  normal compile.
- Result-channel integrity: a per-eval random token is passed to the guest via
  `SB_TOKEN`, captured and scrubbed by the hardening prelude, and embedded in
  both the `/work/out.json` envelope and the stdout sentinel line. The host
  validates the envelope schema and token; forged results (e.g. an `at_exit`
  overwrite or a fake sentinel) become `:sandbox_error`.
- Hardening prelude (`lib/security_box/guest/prelude.rb`): `system`, `exec`,
  `Kernel#spawn`, backticks, `IO.popen`, `Process.spawn` and `Kernel#open` now
  raise `SecurityError` inside the guest (they previously were misleading
  WASI stubs); `ENV` is scrubbed before user code runs; `$stdout.sync = true`.

### Changed

- Guest result envelope carries a `token` field; `system(...)` inside guest
  code raises `SecurityError` instead of returning a stub `true`.
- The sandbox image must be repacked (`rake security_box:build_image`) when
  upgrading: the guest entrypoint protocol changed.

## [0.1.0] - 2026-09-13

### Added

- Initial gem release: `gem install security_box` includes the packed ruby.wasm
  sandbox image (`lib/security_box/assets/security_box.wasm`), so it works out
  of the box without network access or build tools.
- `SecurityBox.eval`, `SecurityBox.warmup`, `SecurityBox::Sandbox` and the
  immutable `SecurityBox::Configuration` with `#with`.
- Limit enforcement: fuel, wall-clock (epoch interruption), memory and
  output-size limits; structured `Result` statuses
  (`:ok`, `:error`, `:timeout`, `:fuel_exhausted`, `:memory_limit`,
  `:sandbox_error`).
- The sandbox image is built with `rake security_box:build_image` from the
  pinned ruby.wasm release (`2.10.1`) and only needs rebuilding when
  `lib/security_box/guest/*.rb` changes or the pin is bumped.