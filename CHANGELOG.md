# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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