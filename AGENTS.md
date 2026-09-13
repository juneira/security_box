# AGENTS.md

Regras e convenções deste projeto para agentes e colaboradores.

## Idioma

1. Todo conteúdo em `docs/` deve estar em português (pt-BR).
2. Comentários no código Ruby (`lib/`, `spec/`, `bin/`, `Rakefile`) devem estar em inglês.
3. Descrições dos specs (`it`, `describe`, `context`) devem estar em inglês.

## Comandos

- Testes: `bundle exec rspec spec/`
- Build da imagem do sandbox: `bundle exec rake security_box:build_image`
- Spike de aprendizado (requer imagem buildada): `bundle exec ruby bin/spike.rb`

## Convenções

- `docs/plan/` documenta o plano e as stages; são documentos vivos, sempre em português.
- A imagem buildada (`build/security_box.wasm`) não vai para o git; repacotar após mudar
  `lib/security_box/guest/*.rb`.
