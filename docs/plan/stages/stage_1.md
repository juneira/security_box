# Stage 1 — Feasibility spike

> Living document: we record here **what we want to learn** in this phase and, at the end,
> **what we learned** (with numbers). The goal is not to deliver the complete library, but to
> reduce the technical uncertainty around ruby.wasm + wasmtime-rb.

## 1. What we want to understand in this phase

| # | Question | How we will answer |
|---|----------|--------------------|
| Q1 | Can we run a Ruby script inside ruby.wasm from the host Ruby, using the `wasmtime` gem? | Pack a `guest/main.rb` with `rbwasm pack` and invoke `_start` via `Wasmtime::Linker` + WASI p1. |
| Q2 | How to capture guest stdout/stderr in a bounded way? | `WasiConfig#set_stdout_buffer` / `#set_stderr_buffer` with maximum capacity. |
| Q3 | How to pass user code into the sandbox? | Option A: `argv` (`set_argv`); Option B: file in a mapped directory (`set_mapped_directory` → `/work`). Validate both and choose. |
| Q4 | How to receive the structured result (value, error, duration) back? | Option A: sentinel line on stdout (forging risk); Option B: `/work/out.json` (sandbox-private file). Validate what works with the embedded VFS of `rbwasm pack`. |
| Q5 | Does an infinite loop die? At what cost? | `epoch_interruption` + `store.set_epoch_deadline` (wall-clock) and `consume_fuel` + `store.set_fuel`. Measure interruption latency. |
| Q6 | How much does it cost to spawn a sandbox? | Time of: `Module.from_file` (once, with cache), `Store.new`, `linker.instantiate`, `invoke("_start")` — cold vs warm. Memory peak. |
| Q7 | What the guest CANNOT do (isolation)? | Try `File.write("/etc/passwd")`, `Dir["/"]`, `system`, `fork`, `require "socket"`, `ENV`, `Thread.new` — all must fail gracefully *inside* the guest. |
| Q8 | Does the wasmtime memory limit work with ruby.wasm? | `Store.new(limits: { memory_size: })` — the guest should get `MemoryOutOfBounds` (and Ruby maps that as `NoMemoryError`/trap). |

## 2. Scope of this phase

- Gemfile with `wasmtime` (runtime) + `ruby_wasm` (build) + `rspec` (tests).
- Image build script (`rake security_box:build_image`): download of the prebuilt tarball
  `ruby-4.0-wasm32-unknown-wasip1-full` and packing with `rbwasm pack`.
- Minimal lib core: `SecurityBox::Sandbox#eval(code) -> Result` in `:oneshot` mode.
- Specs covering Q1–Q8 (including the basic escape matrix).
- `docs/plan/stages/stage_1.md` with the measured numbers (this section 3).

## 3. Learning journal (log)

### Setup

- Host: Ruby 4.0.5, Linux x86_64.
- Gems: `wasmtime` 48.0.1 (precompiled) and `ruby_wasm` 2.10.1 (provides the `rbwasm` CLI).
- Image: download of the release `ruby-4.0-wasm32-unknown-wasip1-full` (binary `ruby` = 36MB);
  packed with `rbwasm pack ruby --dir <tarball>/usr::/usr --dir guest::/src` → **`build/security_box.wasm` at 110MB**.
- **Pitfall 1**: packing only the binary (without `usr::/usr`) leaves the image without stdlib —
  `require "json"` fails with `LoadError`. The whole `usr` directory must go into the VFS at `/usr`.
- **Pitfall 2**: the packed ruby expects `argv = [program_name, script, *args]`. With
  `argv = [script, code]` the ruby treats `code` as the script name (`LoadError`). Correct:
  `set_argv(["ruby", "/src/main.rb", code])` → script = `/src/main.rb`, `ARGV = [code]`.

### Q1/Q2 — execution and output capture (RESOLVED)

- `Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true)` + `Module.from_file` +
  `Wasmtime::Linker` + `Wasmtime::WASI::P1.add_to_linker_sync` + `Store.new(wasi_p1_config:)` +
  `instance.invoke("_start")` runs the guest. ✅
- `set_stdout_buffer(String.new, capacity)` writes **into the same host String object** and truncates at
  the limit. Same pattern for stderr. ✅
- ruby.wasm boot cost: **~240ms per `invoke("_start")`** (p50, stable). `Store.new` ~0.03ms,
  `instantiate` ~0.18ms (p50). Boot dominates the cost of a `:oneshot` sandbox.

### Q3/Q4 — code passing and result return (RESOLVED)

- **Code via argv**: works without a shell (`set_argv`), fine for short codes.
- **Code via `/work/code.rb`**: `set_mapped_directory(tmpdir_host, "/work", :read_write)` at
  runtime **coexists** with the embedded VFS (`/usr`, `/src`) — the wasi-vfs fallthrough works. ✅
  We prefer `/work/code.rb` (no argv size limit).
- **Result via `/work/out.json`**: works ✅ (guest writes the JSON envelope; host reads from the tmpdir).
- **Result via stdout sentinel** (fallback): works ✅.
- ⚠️ Known risk (recorded): malicious code *inside the guest* can forge the envelope
  (e.g., `at_exit` overwriting `out.json`, or printing the sentinel). The channel is reliable against
  accidents, not against an active adversary. Stage 2 mitigations: random token (ENV read and
  erased by the prelude), schema validation on the host, sentinel count check.

### Q5 — interruption (epoch vs fuel) (RESOLVED)

- **Epoch (wall-clock)**: `Engine.new(epoch_interruption: true)` + `engine.start_epoch_interval(25)`
  + `store.set_epoch_deadline(ticks)` → infinite loop killed in **508ms for a 500ms timeout**. ✅
  - **Pitfall 3**: calling `set_epoch_deadline` **before** `instantiate` made the trap fire
    immediately (`:interrupt`). Rule: **set the deadline right before the `invoke`** (that is the
    pattern in the official `examples/epoch.rb`).
- **Fuel**: `consume_fuel: true` + `store.set_fuel(n)` → `Wasmtime::Trap` with `code: :out_of_fuel`. ✅
  - Measured rate of a pure loop (`while true; end`): **~8.4e9 fuel/s** (use as calibration baseline).
  - Epoch and fuel coexist in the same engine/store.

### Q6 — spawn cost (MEASURED)

| Step | p50 |
|---|---|
| `Store.new` | 0.03 ms |
| `instantiate` (module already compiled) | 0.18 ms |
| `invoke("_start")` (ruby boot) | ~240 ms |
| `Module.from_file` (cold compilation, 1x) | ~15 s (!) |

- Cold compilation of the 110MB module costs **~15s** → mandatory compiled module cache
  (`Module#serialize` / `deserialize_file`, Stage 2).
- Host process RSS: stable (~1.3GB after compilation; **no growth** between executions with
  `store.close`).

### Q7 — isolation (VALIDATED)

| Probe | Result |
|---|---|
| `File.write("/etc/passwd")` | `Errno::ENOENT` (guest does not see the host FS) |
| `Dir["/*"]` | `[]` (empty root for the guest) |
| `system("ls")` | returns `true` but **executes nothing** (stub) |
| backtick `` `ls` `` | `ArgumentError` |
| `IO.popen` | `ArgumentError` |
| `fork` | `NotImplementedError` |
| `Thread.new` | `NotImplementedError` (wasip1 without threads) |
| `require "socket"` | `LoadError` (no network) |
| `ENV` | `{}` (sanitized via `set_env({})`) |

Conclusion: the WASI surface is already minimal by default. The hardening prelude (Stage 2) will
exist to neutralize the misleading stubs (`system` returns `true`!) and as defense in depth.

### Q8 — memory limit (WORKS, with a nuance)

- `Store.new(limits: { memory_size: 128MB })` + infinite allocation → the guest dies with
  `[BUG] rb_darray_realloc...` (internal ruby.wasm abort) → trap `:unreachable_code_reached`.
- `store.linear_memory_limit_hit?` → `true` ✅ — we use this flag to map the trap to
  `:memory_limit` reliably.

### Q9 — concurrency (CRITICAL FINDING)

- 4 threads running parallel boots: wall = **sum of the times (ratio 1.05)** → **serial** execution.
- Cause: wasmtime-rb `Instance#invoke` passes `gvl: true` hardcoded to `Func::invoke` (the GVL is
  kept during the wasm execution). `instance.export("_start").to_func.call` also serialized
  (same behavior).
- Implication: **one process = one sandbox at a time**. The epoch deadline keeps working (native
  engine timer), so a stuck guest does not hang the process beyond the timeout — but concurrent
  requests serialize. Real parallelism: multiple processes (Puma workers/sidekiq) for now;
  investigate Ractor in a future stage.

## 4. Implementation delivered

```
Gemfile                                  # wasmtime, ruby_wasm, rspec, rake
Rakefile                                 # spec + rake security_box:build_image
.rspec / .gitignore
bin/spike.rb                             # spike Q1..Q9 (report in the log above)
lib/security_box.rb                      # SecurityBox.eval (shortcut) + requires
lib/security_box/configuration.rb        # immutable (freeze) + #with
lib/security_box/result.rb               # result envelope
lib/security_box/runtime.rb              # Engine cache (epoch timer) and compiled Module
lib/security_box/sandbox.rb              # one-shot Store/Instance, WASI, limits, trap mapping
lib/security_box/errors.rb               # Error, ImageMissing, InvalidConfiguration
lib/security_box/guest/main.rb           # guest packed into /src/main.rb
spec/spec_helper.rb                      # builds the image if missing
spec/security_box/configuration_spec.rb  # 5 examples
spec/security_box/sandbox_spec.rb        # 16 examples (integration + isolation matrix)
```

### Final numbers (lib level, host Ruby 4.0.5)

| Metric | Value |
|---|---|
| `SecurityBox::Sandbox#eval` (p50, after warmup) | **257 ms** (dominated by the ruby.wasm boot: ~240ms) |
| `Store.new` + `instantiate` | ~0.2 ms |
| `Module.from_file` (cold compilation, 1x per process) | ~15 s |
| Host process RSS (15 evals) | stable at ~1.3GB, no leak with `store.close` |
| Epoch interruption 500ms | 508–518 ms (precision ~±20ms) |
| Fuel of pure loop | ~8.4e9 fuel/s |
| RSpec suite (21 examples) | **21/21 green in ~21s** |

### Tests (covered matrix)

Basic execution with value/stdout; multiple executions; JSON serialization and `inspect` fallback;
user exception (`:error` + class/message); `SystemExit`; epoch timeout; fuel;
memory limit; stdout truncation; and isolation: FS (`/etc/passwd`, `Dir["/*"]`),
`system` (harmless stub), `fork`, `require "socket"`, `Thread.new`, empty `ENV`.

### Implementation learnings (beyond the spike)

- `NotImplementedError` and `LoadError` inherit from `ScriptError`, **not** from `StandardError` —
  the guest needs `rescue Exception` to report them in the envelope (spec covers it).
- wasmtime traps: `:interrupt` → timeout, `:out_of_fuel` → fuel, `:memory_out_of_bounds`/`linear_memory_limit_hit?`
  → memory limit, others → `:sandbox_error`.
- `Wasmtime::WasiExit` happens when the guest exits without an envelope (e.g., `exit!`) → `:sandbox_error`.
- The round-trip `JSON.parse(JSON.generate(value))` in the guest normalizes symbols/non-serializable
  objects into what the host will actually read.
- `store.close` in the `ensure` is essential for memory stability.

## 5. Decisions made in this phase

1. **Code delivery**: file `/work/code.rb` via `set_mapped_directory` (argv as fallback).
2. **Result**: `/work/out.json` (JSON envelope), with a stdout sentinel fallback.
3. **Interruption**: epoch as the wall-clock limit (mandatory) + fuel as a deterministic budget
   (optional per config). Deadline always set immediately before the `invoke`.
4. **Result status**: `:ok`, `:error` (user code error), `:timeout`, `:fuel_exhausted`,
   `:memory_limit` (via `linear_memory_limit_hit?`), `:sandbox_error`.
5. **Shared runtime**: `Engine` + `Module` memoized per config (mutex); `Module` compiled
   once per process (~15s on the first spawn — disk cache lands in Stage 2).
6. **v1 concurrency**: serial per process; horizontal scaling via processes. Documented as a
   limitation; Ractor stays for a future stage.

## 6. Pending items for Stage 2

- [ ] Disk cache of the `.wasm` image and the compiled module (`Module#serialize`/`deserialize_file`)
      — eliminates the ~15s of cold compilation on every process.
- [ ] Result channel with token (ENV erased by the prelude) + schema validation on the host.
- [ ] Hardening prelude: neutralize `system`, backtick, `IO.popen`, `Kernel#open`, `ENV` after reading.
- [ ] Full `Configuration` (named profiles, `#with`, fingerprint) — today only the core.
- [ ] Investigate: minimum viable `memory_size` for the ruby.wasm boot (the 512MB default is
      conservative); fuel rates per workload type.
- [ ] Investigate: Ractor for real parallelism (Engine is `frozen_shareable` in wasmtime-rb).
- [ ] Benchmark: spawn with `InstanceAllocationStrategy::Pooling`.
