# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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