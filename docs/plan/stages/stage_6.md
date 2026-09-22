# Stage 6 — Host RPC ("code mode"): blocking `SB.call` via a wasm import

> Status: delivered in gem 0.6.0. Spike: `bin/spike_stage6_rpc.rb`
> (8/8 PASS). All measurements below are from this machine (6 cores,
> ruby 4.0.5 host, wasmtime-rb 48.0.1, ruby_wasm 2.10.1, wasi-sdk 24.0).

## 1. Goal

Let code running inside the sandbox call host functions — MCP tools in the
intended use — with **blocking semantics**: `SB.call("tool", args: ...)`
reads to the LLM that generated the code as a plain Ruby function call, no
callbacks or async shapes. Two designs were on the table:

1. **Suspend/resume (replay)** — guest exits with a "suspended" envelope,
   host executes the tool, host re-invokes the same program with a growing
   log of served calls. Works with zero image changes, but costs one guest
   reboot (~260ms) per call, requires a determinism contract and
   request/log matching machinery.
2. **Blocking import** — a C extension statically linked into the image
   declares a wasm import; the host defines it with
   `Wasmtime::Linker#func_new` and the closure runs inline while the wasm
   is suspended. No replay, no rounds, ~zero cost per call.

Stage-4 evidence said "worker mode is infeasible because `invoke` holds
the GVL" — the distinction that unblocks option 2: the GVL blocks the
**polling** model (host observing a running guest), not the **import**
model (the host function runs on the invoking thread, inside `invoke`).

## 2. Spike results (Q1–Q8)

| Probe | Result |
|---|---|
| Q1 image build | `rbwasm build` (guest Gemfile, `sb_rpc` native gem statically linked) + `rbwasm pack --dir guest::/src` — 49.8MB image |
| Q2 `require "sb_rpc"` | Works via generated `/bundle/setup.rb` ($LOAD_PATH unshift) + statically registered `Init_sb_rpc` (feature `sb_rpc.so`) |
| Q3 round-trip | Guest → import → handler → value; fuel ~0.92e9/eval (boot-dominated) |
| Q4 blocking | Guest observes ~400ms of wall-clock inside `SB.call`, continues linearly |
| Q5 handler errors | Encoded as `{"ok":false,"error":{class,message}}` response → guest `SB::ToolError`; an unrescued closure raise surfaces as a **raw Ruby exception through `invoke`** (must never happen — the closure rescues `Exception`) |
| Q6 unknown name | Guest-rescuable `SB::UnknownTool`; host unaffected |
| Q7 transcript | Per-eval calls visible via `caller.store_data` |
| Q8a slow handler | Not interrupted while the wasm is suspended in the import |
| Q8b deadline | With a **working epoch timer**, the guest traps at the first epoch check after the deadline passes (total wall-clock includes handler time) |

Key hazards found and fixed during the spike:

- **Epoch timer must be native** (`Engine#start_epoch_interval`): a Ruby
  timer thread never runs during `invoke` (GVL) — reconfirmed stage-4 Q1.
  With the native timer, `timeout_ms` semantics are: boot + guest compute +
  handler time all count; the handler itself is not preempted.
- **Fuel is not consumed by host code** (only wasm instructions burn it).
- **`JSON.generate` does not raise on arbitrary objects** — `Object.new`
  serializes as its inspect string (`Object#to_json` fallback); "args must
  be JSON-serializable" is enforced by serialization *shape*, not by
  rejection.
- Image build paths: `rbwasm pack --dir` needs the real host path (a
  `./` + absolute-path concatenation fails with `os error 2`); the build
  subprocess must run from `lib/security_box/guest_ext` under its own
  bundle with the parent's bundler injection stripped, or the wrong
  lockfile gets rewritten.

## 3. Design as shipped

### Protocol

```
guest: SB.call(name, args)
  → writes /work/rpc_req.json   {"name", "args"}
  → SBExt.call                  (wasm import "sb"/"call"; guest blocks)
host closure (per-eval state via caller.store_data):
  → reads request, dispatches handlers[name]
  → writes /work/rpc_resp.json  {"ok", "result"} | {"ok":false,"error":{class,message}}
  → returns 0
guest: reads response → result | SB::ToolError / SB::UnknownTool / SB::RpcUnavailable
```

- **Import always defined**: the image statically declares the import, so
  `GuestRpc.define_import(linker)` runs on every linker (Sandbox,
  RactorPool workers) even with no handlers configured; guest calls then
  get a clean `SB::UnknownTool` ("no RPC handlers are configured…")
  instead of a failed instantiation.
- **Per-eval state, shared closure**: handlers, workdir and the transcript
  travel in Store data (`caller.store_data`); the closure captures
  nothing — safe across evals, threads and Ractor workers.
- **Transcript**: every call (ok or failed) is recorded and frozen onto
  `Result#rpcs` — debugging surface for agents.
- **Limits** (host-side): `MAX_CALLS = 1000` per eval,
  `RESULT_LIMIT = 1 MiB` per response (oversized → guest `SB::ToolError`).
- **Configuration**: `c.rpc "name" => handler` (append, like `c.mount`),
  `rpcs:` replaces on `#with`/per-call (like `env:`); `Rpcs` validation
  mirrors `Mounts` (unique non-empty String names, `#call`-able, ≤64).
  Handlers are excluded from `#fingerprint` (Procs have no stable
  identity) and are **rejected on `RactorPool`** (Procs cannot cross a
  Ractor boundary — raised at construction and per eval).

### Guest side (`lib/security_box/guest/rpc.rb`)

`SB.call(name, args = nil, **kwargs)` — validates the name, serializes the
request, invokes `SBExt.call`, maps the response to a value or to
`SB::ToolError`/`SB::UnknownTool` (rescuable). Defined before user code;
loads the gem via the generated `/bundle/setup.rb` and degrades to
`SB::RpcUnavailable` when the image has no guest gems.

### Host side (`lib/security_box/guest_rpc.rb`)

`GuestRpc.define_import` + `store_data` + the serving closure. Every
failure path is encoded as a response — `rescue Exception` at the
boundary (spike Q5 showed uncaught raises escape `invoke` as raw Ruby
exceptions). Handler messages are sanitized (`class` + `message`, no
backtrace, no host paths). Results are JSON round-tripped (inspect-string
fallback), never Marshal'd.

## 4. Security posture

| Threat | Posture |
|---|---|
| Guest-supplied args | Inherent to code mode: the host executes the registered handler with the args the code passed. Authorization lives in the handler/allowlist (host-side) |
| Forging the channel | The import is the boundary — guest code can call `SBExt.call` arbitrarily or monkeypatch `SB.call`; it can only trigger handlers *it names*, which is the feature. The envelope/token channel is unchanged |
| Handler leaks | Errors sanitized (no backtrace/paths); results JSON-only; response size capped |
| DoS | `MAX_CALLS` per eval + fuel (guest pays for its own JSON work) + epoch/fuel limits per eval unchanged |
| Ractor isolation | No Procs cross Ractors (pool rejects rpcs; stripped configs; stateless closure) |
| Concurrency (Pool) | Handlers run on the eval thread inside `invoke`; blocking I/O inside a handler releases the GVL for other host threads. Handler thread-safety is the user's responsibility (documented) |

## 5. Measured numbers (new image, `rbwasm build` flow)

- Image size: **49.8MB** (was ~110MB packed release tarball).
- Memory floor: **~36MiB (576 pages)** — was 1528 pages (~95.5MiB).
  96/80/72/64MB boot `:ok`; 56–36MB → `:memory_limit`; ≤35MB →
  `:sandbox_error` (instantiation).
- Eval fuel (boot + trivial eval): ~0.92e9 (stage-3 calibration held).
- Suite: 185 examples green; wall time ~20s (was ~41s against the old
  image — faster boot).
- Cost per RPC: ~0.3ms per call (JSON + two tmpfs file writes) + handler
  time; guest-side fuel for the JSON round-trip is negligible.

## 6. What the design deliberately does not do

- **No RactorPool rpcs** (v1): handlers are main-Ractor state. A mailbox
  design (worker closure → `Ractor.main <<` → collector routes the
  response back to a per-request `Queue`) is sketched and deferred —
  spike-gated fast-follow.
- **No signed RPC log / request authorization layer**: the mechanism is
  raw RPC with an allowlist; policy (per-identity quotas, audit,
  MCP-level authz) belongs to the handler layer.
- **No deadline re-arm around slow handlers** (v1): `timeout_ms` covers
  the whole eval including handler time — document and size timeouts
  accordingly. `caller.store_data[:store].set_epoch_deadline` from inside
  the closure was proven to work (spike), so per-call extension is
  available later without protocol changes.
