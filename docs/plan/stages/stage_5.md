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

### Setup

- Host: Ruby 4.0.5, Linux x86_64; `wasmtime` 48.0.1, `ruby_wasm` 2.10.1; existing
  packed image (no guest changes needed this stage).
- API verification up front: `WasiConfig#set_mapped_directory(host, guest, mode)`
  takes exactly 3 arguments and accepts `:read_only` / `:read_write`. **It silently
  accepts unknown mode symbols** (`:bogus` returns the WasiConfig without error), so
  the mode must be validated in `Configuration::Mounts`, never trusted to wasmtime.

### Q1 — read-only mounts (RESOLVED — enforced, with `EPERM` not `EROFS`)

- Reads all work: `File.read`, `Dir["/**/*"]`, `File.open` blocks, nested
  subdirectories. The mount root appears at the guest path (`/data`), and
  `Dir["/*"]` at the guest root still returns `[]` (preopens are not listed by glob).
- Write attempts all fail **guest-side** with `Errno::EPERM` (`File.write`,
  `File.open(..., "w")`, append mode, `Dir.mkdir`, `File.delete`, `File.rename`);
  `File.chmod` fails with `Errno::ENOSYS` (WASI has no chmod). The host directory is
  byte-for-byte unchanged after the run.
- Not the `Errno::EROFS` the question guessed: wasi-vfs surfaces
  NOTCAPABLE-style denial as `EPERM` in the guest. The spec matrix expects
  `Errno::EPERM`.

### Q1b — symlink escapes (RESOLVED — blocked by wasmtime)

- In-tree symlink (`link -> hello.txt`): reads fine.
- Absolute symlink out (`link -> /etc/hostname`) and relative escape
  (`link -> ../../etc/hostname`): both fail with `Errno::EPERM` — path resolution is
  capped at the preopen root.
- Bonus probe: the guest cannot even **create** symlinks (`File.symlink` →
  `Errno::EPERM`), so a writable `/work` cannot be used to stage an escape either.

### Q1c — writable mounts (RESOLVED — round-trip works)

- `mount_rw`: guest writes land on the host (`host sees guest-written file: true`)
  and reads of seeded files work.

### Q2 — N mounts + `/work` + embedded VFS (RESOLVED — coexist; collisions are silently shadowed)

- 4 extra mounts + `/work` (rw) + stdlib (`require "json"`) + `/src/main.rb` all
  work simultaneously — the wasi-vfs fallthrough scales past stage 1's single mount.
- **Shadowing**: a mount colliding exactly with `/usr` or `/src` is **silently
  useless** — the embedded VFS wins, the mounted marker file reads as `ENOENT`,
  and the stdlib keeps loading. No error is raised by wasmtime. → the library must
  reject collisions itself (they are invisible failures otherwise).
- Two mounts at the same guest path: **last one wins** (`second\n` read back).
  Again silent — duplicates must be rejected at the configuration level.
- `Dir["/*"]` stays `[]` even with mounts (preopens are not glob-listable), so
  mounted paths must be known by name.

### Q2b — mounts inside the reserved trees (RESOLVED — break things; hard-reject)

- A mount at `/usr/local` **breaks the guest boot entirely** (WASI exit code 1
  before any Ruby code runs — require paths resolve through the mount).
- A mount at `/work/sub` works but is a read-only subtree under the writable tmpdir
  (writes into it fail with `EPERM`) — confusing semantics.
- Decision (with the user): hard-reject any guest path overlapping `/work`, `/usr`
  or `/src`, exact or nested (`guest == r`, `guest.start_with?(r + "/")`,
  `r.start_with?(guest + "/")`).

### Q3 — host-side failure modes (RESOLVED — validate before Store.new)

- Nonexistent host dir: `Wasmtime::Store.new` raises
  `Wasmtime::Error: No such file or directory (os error 2)`.
- Host path is a file: `Wasmtime::Error: Not a directory (os error 20)`.
- Both surface at `Store.new` (the `WasiConfig` construction itself succeeds), and
  in the pre-stage `EvalRun` the `Store.new` call sat **outside** the
  `rescue Wasmtime::Error` — bad mounts would have raised out of `#eval`.
  Fixes: (1) per-eval validation of every mount's host path (`File.directory?`)
  before any store setup, mapped to a `:sandbox_error` Result with a
  `security_box:` note; (2) `Store.new` moved inside the rescue as defense in
  depth (wasmtime setup can no longer raise out of `#eval`).

### Q4 — per-eval cost (RESOLVED — free)

| Mounts | warm-boot p50 (5 runs) |
|---|---|
| 0 | 263.5 ms |
| 1 | 259.0 ms |
| 4 | 263.0 ms |
| 8 | 261.7 ms |

→ Within noise: WASI preopen setup is not a hotspot; MAX_MOUNTS=16 costs nothing.

### Q5 — API shape (RESOLVED — delivered as proposed)

- `c.mount "host/path" => "/data"` (read-only) + `c.mount_rw`; one pair per call,
  accumulating; relative host paths expanded against `Dir.pwd` at DSL time (per the
  plan's `c.mount "./data" => "/data"` example; the fingerprint records the resolved
  absolute path).
- `mounts` is a `Configuration` value: frozen array of frozen `{host:, guest:, mode:}`
  hashes; `#with(mounts:)` replaces (like `env:`); the fingerprint covers mounts via
  `to_h`; profiles, per-call overrides and RactorPool requests need no special-casing
  (Configuration was already passed through Ractor ports).
- Validation lives in `Configuration::Mounts` (shape/modes/normalization/reserved/
  duplicates/count — all `InvalidConfiguration`), while *existence* of the host dir
  is per-eval in `EvalRun` (directories can vanish between registration and eval).

### Q6 — embedded VFS tampering (RESOLVED — not possible; no prelude change)

- `File.write("/usr/...")`, `File.write("/src/...")`, `File.write("/...")` (root):
  all fail with `Errno::ENOENT` (the paths read as non-existent to write attempts).
- `File.delete("/usr/local/bin/ruby")`: `Errno::ENOTSUP`.
- **Decision: no prelude File-write restriction** (evidence-gated answer). WASI
  already prevents tampering with the embedded VFS and the guest root; adding a
  prelude refinement would cost an image repack for no measurable gain. Documented
  as a revisit trigger only if wasmtime behavior changes.

## 4. Implementation delivered

```
bin/spike_stage5_mounts.rb                  # Q1–Q6 probes (RO matrix, collisions, latency, VFS tamper)
bin/spike_stage5_extra.rb                   # reserved-tree overlap + symlink cross-preopen probes
lib/security_box/configuration.rb           # Mounts module (validation) + mount/mount_rw DSL + #with/#fingerprint
lib/security_box/eval_run.rb                # per-eval mount validation + mounts after /work; Store.new inside rescue
lib/security_box/sandbox.rb                 # per-call `mounts:` override documented
spec/security_box/mounts_spec.rb            # 29 examples: Mounts matrix, DSL, #with/#fingerprint, integration, RactorPool
README.md, CHANGELOG.md                     # 0.5.0 (mount section, isolation matrix, security notes)
docs/PLAN.md                                # §2/§4/§5/§7/§9/§10/§11 updated to delivered state
```

No guest changes: the image was not repacked (Q6 decided against a prelude change).

## 5. Decisions made in this phase

1. **Read-only by default, wasmtime-enforced** (Q1): `:read_only` preopens deny
   writes guest-side with `Errno::EPERM`; `mount_rw` is the only writable path
   besides `/work`. The mode is validated in `Mounts` because wasmtime silently
   accepts bogus mode symbols.
2. **Hard-reject reserved overlaps** (Q2b, user decision): exact or nested overlap
   with `/work`, `/usr`, `/src` raises `InvalidConfiguration` — a collision is
   silently shadowed by the embedded VFS, a mount inside `/usr` breaks the guest
   boot, and inside `/work` it would create a confusing read-only subtree.
3. **Two-layer validation** (Q3): shape/normalization/reserved/duplicates/count in
   `Configuration::Mounts` (at registration, feeding the fingerprint); host-path
   existence in `EvalRun` per eval, mapped to `:sandbox_error` + `security_box:`
   note (paths vanish at runtime; `Store.new` was also moved inside the rescue so
   wasmtime setup failures can never raise out of `#eval`).
4. **Relative host paths expand at DSL time** (Q5, user decision): matches the
   planned `c.mount "./data" => "/data"` example and makes fingerprints stable per
   resolved location.
5. **MAX_MOUNTS = 16** (user decision): generous ceiling; Q4 showed mount count has
   no latency cost, so the cap is only a sanity bound.
6. **No prelude refinement** (Q6, evidence-gated per user decision): the embedded
   VFS is not guest-writable and symlink creation is unsupported — WASI is the
   enforcement layer; no image repack required this stage.
7. **Symlink posture documented** (Q1b): wasmtime caps path resolution at the
   preopen root, so mounted symlinks cannot escape; the guest cannot create
   symlinks at all. No extra validation needed host-side.

## 6. Pending items for Stage 6

Stage 6 is M3: `ImageBuilder` + fingerprint-keyed caches (per `docs/PLAN.md` §9).

- [ ] `ImageBuilder` (ruby version, `:full`/`:minimal` profile, stdlib allowlist,
      pure-Ruby gems) — the mounts feature composes with `:minimal` images
      unchanged (mounts are a runtime concern, not an image concern).
- [ ] Fingerprint-keyed image cache (`~/.cache/security_box/images/<sha>.wasm`) and
      compiled-module cache identity; explicit build step; `ImageMissing` when
      production forbids builds.
- [ ] For stage 7 (`docs/SECURITY.md`): the mount threat model notes from this stage
      (content fully readable; writable mounts are part of the guest's blast radius;
      symlink behavior) need to land in the threat model.
- [ ] Backlog (from this stage): none new. Pre-existing backlog unchanged (see
      `stage_4.md` §6: digest sidecar only if sub-100ms boot matters; revisit
      `:worker` mode on GVL-releasing wasmtime-rb; `RactorPool` hardening).
