# AGENTS.md

Rules and conventions of this project for agents and collaborators.

## Language

1. All content in this project (docs, code comments, spec descriptions, log
   messages, error messages) must be in English.

## Commands

- Tests: `bundle exec rspec spec/`
- Sandbox image build: `bundle exec rake security_box:build_image`
  (first build downloads the Ruby source, wasi-sdk and binaryen into
  `build/`; network required once)
- Learning spike (requires built image): `bundle exec ruby bin/spike.rb`
- RPC spike (builds its own image into `build/spike_rpc.wasm`):
  `bundle exec ruby bin/spike_stage6_rpc.rb`

## Conventions

- `docs/plan/` documents the plan and the stages; these are living documents.
- The built image (`lib/security_box/assets/security_box.wasm`) is not committed
  to git; rebuild after changing `lib/security_box/guest/*.rb` or anything
  under `lib/security_box/guest_ext/` (guest gems).
