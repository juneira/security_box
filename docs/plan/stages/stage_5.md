# Stage 5 — Folder mounts

> Living document: we record here **what we want to learn** in this phase and, at the
> end, **what we learned** (with numbers). Goal of this phase: complete the M2 leftover
> from the original plan — explicit host-folder mounts into the sandbox, read-only by
> default — so guest code can safely read a host directory (e.g., a script processing
> a mounted data folder).

## 1. What we want to understand in this phase

| # | Question | How we will answer |
|---|----------|--------------------|
| Q1 | Do read-only mapped directories behave correctly? | `set_mapped_directory(host, path, :read_only)`; probe reads (`File.read`, `Dir[]`, `File.open`) and write attempts (`File.write`, `File.open(..., "w")` — expect `Errno::EROFS` or the WASI equivalent). |
| Q2 | Do N extra mounts + `/work` coexist with the embedded VFS? | Mount multiple host dirs simultaneously; verify the wasi-vfs fallthrough/shadowing rules against `/usr`, `/src` and `/work` (stage 1 proved one extra mount; validate several and precedence on collision). |
| Q3 | What must host-side validation enforce before mounting? | Absolute host paths, existing directories, guest-path collisions (`/work`, `/usr`, `/src`, duplicates, shadowing), a mount-count limit, and clear error mapping into a Result. |
| Q4 | What does mounting cost per eval? | Warm-boot latency with 0/1/N mounts (WASI config construction + WASI preopen cost). |
| Q5 | API shape | Builder DSL `c.mount "host/path" => "/data"` (read-only by default) + `c.mount_rw`; per-call overrides via `#with`; interaction with profiles and `#fingerprint` (mounts are config values, so the fingerprint already covers them). |
| Q6 | Does the prelude need File-write restrictions when there is no RW mount? | Probe guest writes into the embedded VFS paths (`/usr`, `/src`) — can user code tamper with them? Decide whether a prelude refinement (deny `File` write ops without a writable mount) is warranted as defense in depth. |

## 2. Scope of this phase

- `lib/security_box/configuration.rb` — `mount`/`mount_rw` in the Builder DSL +
  `#with` + host/guest path validation.
- `lib/security_box/eval_run.rb` — apply mounts after `/work`; failures mapped to a
  clear Result (`:sandbox_error` with a `security_box:` note) instead of raising.
- Specs: read-only matrix (reads work, writes fail), collision matrix, `/work`
  coexistence, profile/override plumbing.
- README + PLAN.md updates (public API + defense matrix).
- `docs/plan/stages/stage_5.md` with the measured numbers (this document).

Out of scope (later stages): `ImageBuilder` and fingerprint-keyed caches (stage 6);
CLI (stage 7); writable mounts outside `/work` beyond the explicit `mount_rw` API.

## 3. Learning journal (log)

(to be filled during the phase)

## 4. Implementation delivered

(to be filled at the end)

## 5. Decisions made in this phase

(to be filled at the end)

## 6. Pending items for Stage 6

(to be filled at the end)