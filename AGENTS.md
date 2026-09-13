# AGENTS.md

Rules and conventions of this project for agents and collaborators.

## Language

1. All content in this project (docs, code comments, spec descriptions, log
   messages, error messages) must be in English.

## Commands

- Tests: `bundle exec rspec spec/`
- Sandbox image build: `bundle exec rake security_box:build_image`
- Learning spike (requires built image): `bundle exec ruby bin/spike.rb`

## Conventions

- `docs/plan/` documents the plan and the stages; these are living documents.
- The built image (`lib/security_box/assets/security_box.wasm`) is not committed
  to git; repack after changing `lib/security_box/guest/*.rb`.
