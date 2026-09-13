# Stage 1 — Spike de viabilidade

> Documento vivo: registramos aqui **o que queremos aprender** nesta fase e, ao final,
> **o que aprendemos** (com números). O objetivo não é entregar a lib completa, e sim
> reduzir a incerteza técnica do ruby.wasm + wasmtime-rb.

## 1. O que queremos entender nesta fase

| # | Pergunta | Como vamos responder |
|---|----------|----------------------|
| Q1 | Conseguimos rodar um script Ruby dentro do ruby.wasm a partir do Ruby host, usando a gem `wasmtime`? | Empacotar um `guest/main.rb` com `rbwasm pack` e invocar `_start` via `Wasmtime::Linker` + WASI p1. |
| Q2 | Como capturar stdout/stderr do guest de forma limitada? | `WasiConfig#set_stdout_buffer` / `#set_stderr_buffer` com capacidade máxima. |
| Q3 | Como passar o código do usuário para dentro do sandbox? | Opção A: `argv` (`set_argv`); Opção B: arquivo em diretório mapeado (`set_mapped_directory` → `/work`). Validar as duas e escolher. |
| Q4 | Como receber o resultado estruturado (valor, erro, duração) de volta? | Opção A: linha-sentinela no stdout (risco de forja); Opção B: `/work/out.json` (arquivo privado do sandbox). Validar o que funciona com o VFS embutido do `rbwasm pack`. |
| Q5 | Loop infinito morre? Com qual custo? | `epoch_interruption` + `store.set_epoch_deadline` (wall-clock) e `consume_fuel` + `store.set_fuel`. Medir latência da interrupção. |
| Q6 | Quanto custa spawnar um sandbox? | Tempo de: `Module.from_file` (uma vez, com cache), `Store.new`, `linker.instantiate`, `invoke("_start")` — frio vs quente. Pico de memória. |
| Q7 | O que o guest NÃO consegue fazer (isolamento)? | Tentar `File.write("/etc/passwd")`, `Dir["/"]`, `system`, `fork`, `require "socket"`, `ENV`, `Thread.new` — tudo deve falhar graciosamente *dentro* do guest. |
| Q8 | Memory limit do wasmtime funciona com o ruby.wasm? | `Store.new(limits: { memory_size: })` — o guest deve receber `MemoryOutOfBounds` (e o Ruby mapeia isso como `NoMemoryError`/trap). |

## 2. Escopo desta fase

- Gemfile com `wasmtime` (runtime) + `ruby_wasm` (build) + `rspec` (testes).
- Script de build da imagem (`rake security_box:build_image`): download do tarball pré-compilado
  `ruby-4.0-wasm32-unknown-wasip1-full` e empacotamento com `rbwasm pack`.
- Núcleo mínimo da lib: `SecurityBox::Sandbox#eval(code) -> Result` em modo `:oneshot`.
- Specs cobrindo Q1–Q8 (incluindo a matriz de escapes básica).
- `docs/plan/stages/stage_1.md` com os números medidos (esta seção 3).

## 3. Diário de aprendizado (log)

### Setup

- Host: Ruby 4.0.5, Linux x86_64.
- Gems: `wasmtime` 48.0.1 (pré-compilada) e `ruby_wasm` 2.10.1 (fornece o CLI `rbwasm`).
- Imagem: download do release `ruby-4.0-wasm32-unknown-wasip1-full` (binário `ruby` = 36MB);
  empacotada com `rbwasm pack ruby --dir <tarball>/usr::/usr --dir guest::/src` → **`build/security_box.wasm` de 110MB**.
- **Armadilha 1**: empacotar só o binário (sem `usr::/usr`) deixa a imagem sem stdlib — `require "json"`
  falha com `LoadError`. O diretório `usr` inteiro precisa ir para o VFS em `/usr`.
- **Armadilha 2**: o ruby empacotado espera `argv = [program_name, script, *args]`. Com
  `argv = [script, code]` o ruby trata `code` como nome do script (`LoadError`). Correto:
  `set_argv(["ruby", "/src/main.rb", code])` → script = `/src/main.rb`, `ARGV = [code]`.

### Q1/Q2 — execução e captura de saída (RESOLVIDO)

- `Wasmtime::Engine.new(consume_fuel: true, epoch_interruption: true)` + `Module.from_file` +
  `Wasmtime::Linker` + `Wasmtime::WASI::P1.add_to_linker_sync` + `Store.new(wasi_p1_config:)` +
  `instance.invoke("_start")` roda o guest. ✅
- `set_stdout_buffer(String.new, capacity)` escreve **no mesmo objeto String do host** e trunca no
  limite. Mesmo padrão para stderr. ✅
- Custo de boot do ruby.wasm: **~240ms por `invoke("_start")`** (p50, estável). `Store.new` ~0.03ms,
  `instantiate` ~0.18ms (p50). O boot domina o custo de um sandbox `:oneshot`.

### Q3/Q4 — passagem de código e retorno de resultado (RESOLVIDO)

- **Código via argv**: funciona sem shell (`set_argv`), ok para códigos curtos.
- **Código via `/work/code.rb`**: `set_mapped_directory(tmpdir_host, "/work", :read_write)` em
  runtime **coexiste** com o VFS embutido (`/usr`, `/src`) — o fallthrough do wasi-vfs funciona. ✅
  Preferimos `/work/code.rb` (sem limite de tamanho de argv).
- **Resultado via `/work/out.json`**: funciona ✅ (guest escreve envelope JSON; host lê do tmpdir).
- **Resultado via sentinela no stdout** (fallback): funciona ✅.
- ⚠️ Risco conhecido (registrado): código malicioso *dentro do guest* pode forjar o envelope
  (ex.: `at_exit` sobrescrevendo `out.json`, ou imprimindo a sentinela). O canal é confiável contra
  acidentes, não contra adversário ativo. Mitigações para Stage 2: token aleatório (ENV lido e
  apagado pelo prelude), validação de schema no host, contagem de sentinelas.

### Q5 — interrupção (epoch vs fuel) (RESOLVIDO)

- **Epoch (wall-clock)**: `Engine.new(epoch_interruption: true)` + `engine.start_epoch_interval(25)`
  + `store.set_epoch_deadline(ticks)` → loop infinito morto em **508ms para timeout de 500ms**. ✅
  - **Armadilha 3**: chamar `set_epoch_deadline` **antes** de `instantiate` fez o trap disparar
    imediatamente (`:interrupt`). Regra: **setar o deadline logo antes do `invoke`** (é o padrão do
    exemplo oficial `examples/epoch.rb`).
- **Fuel**: `consume_fuel: true` + `store.set_fuel(n)` → `Wasmtime::Trap` com `code: :out_of_fuel`. ✅
  - Taxa medida de loop puro (`while true; end`): **~8.4e9 fuel/s** (usar como base de calibração).
  - Epoch e fuel coexistem no mesmo engine/store.

### Q6 — custo de spawn (MEDIDO)

| Etapa | p50 |
|---|---|
| `Store.new` | 0.03 ms |
| `instantiate` (módulo já compilado) | 0.18 ms |
| `invoke("_start")` (boot do ruby) | ~240 ms |
| `Module.from_file` (compilação fria, 1x) | ~15 s (!) |

- Compilação fria do módulo de 110MB custa **~15s** → cache obrigatório de módulo compilado
  (`Module#serialize` / `deserialize_file`, Stage 2).
- RSS do processo host: estável (~1.3GB após compilação; **sem crescimento** entre execuções com
  `store.close`).

### Q7 — isolamento (VALIDADO)

| Probe | Resultado |
|---|---|
| `File.write("/etc/passwd")` | `Errno::ENOENT` (guest não vê FS do host) |
| `Dir["/*"]` | `[]` (root vazio para o guest) |
| `system("ls")` | retorna `true` mas **não executa nada** (stub) |
| backtick `` `ls` `` | `ArgumentError` |
| `IO.popen` | `ArgumentError` |
| `fork` | `NotImplementedError` |
| `Thread.new` | `NotImplementedError` (wasip1 sem threads) |
| `require "socket"` | `LoadError` (sem rede) |
| `ENV` | `{}` (saneado via `set_env({})`) |

Conclusão: a superfície WASI já é mínima por padrão. O prelude de hardening (Stage 2) existirá para
neutralizar os stubs enganosos (`system` retorna `true`!) e defesa em profundidade.

### Q8 — memory limit (FUNCIONA, com nuance)

- `Store.new(limits: { memory_size: 128MB })` + alocação infinita → o guest morre com
  `[BUG] rb_darray_realloc...` (abort interno do ruby.wasm) → trap `:unreachable_code_reached`.
- `store.linear_memory_limit_hit?` → `true` ✅ — usamos esse flag para mapear o trap como
  `:memory_limit` de forma confiável.

### Q9 — concorrência (ACHADO CRÍTICO)

- 4 threads rodando boots paralelos: wall = **soma dos tempos (ratio 1.05)** → execução **serial**.
- Causa: `Instance#invoke` do wasmtime-rb passa `gvl: true` hardcoded para `Func::invoke` (o GVL é
  mantido durante a execução do wasm). `instance.export("_start").to_func.call` também serializou
  (mesmo comportamento).
- Implicação: **um processo = um sandbox por vez**. Deadline de epoch continua funcionando (timer
  nativo do engine), então um guest travado não trava o processo além do timeout — mas requisições
  concorrentes serializam. Paralelismo real: múltiplos processos (Puma workers/sidekiq) por enquanto;
  investigar Ractor em stage futura.

## 4. Implementação entregue

```
Gemfile                                  # wasmtime, ruby_wasm, rspec, rake
Rakefile                                 # spec + rake security_box:build_image
.rspec / .gitignore
bin/spike.rb                             # spike Q1..Q9 (relatório no log acima)
lib/security_box.rb                      # SecurityBox.eval (atalho) + requires
lib/security_box/configuration.rb        # imutável (freeze) + #with
lib/security_box/result.rb               # envelope de resultado
lib/security_box/runtime.rb              # cache de Engine (timer de epoch) e Module compilado
lib/security_box/sandbox.rb              # Store/Instance one-shot, WASI, limites, mapeamento de traps
lib/security_box/errors.rb               # Error, ImageMissing, InvalidConfiguration
lib/security_box/guest/main.rb           # guest empacotado em /src/main.rb
spec/spec_helper.rb                      # builda a imagem se faltar
spec/security_box/configuration_spec.rb  # 5 exemplos
spec/security_box/sandbox_spec.rb        # 16 exemplos (integração + matriz de isolamento)
```

### Números finais (nível lib, host Ruby 4.0.5)

| Métrica | Valor |
|---|---|
| `SecurityBox::Sandbox#eval` (p50, após warmup) | **257 ms** (dominado pelo boot do ruby.wasm: ~240ms) |
| `Store.new` + `instantiate` | ~0.2 ms |
| `Module.from_file` (compilação fria, 1x por processo) | ~15 s |
| RSS do processo host (15 evals) | estável em ~1.3GB, sem vazamento com `store.close` |
| Interrupção epoch 500ms | 508–518 ms (precisão ~±20ms) |
| Fuel de loop puro | ~8.4e9 fuel/s |
| Suíte RSpec (21 exemplos) | **21/21 verde em ~21s** |

### Testes (matriz coberta)

Execução básica com valor/stdout; múltiplas execuções; serialização JSON e fallback `inspect`;
exceção do usuário (`:error` + class/message); `SystemExit`; timeout por epoch; fuel;
memory limit; truncamento de stdout; e isolamento: FS (`/etc/passwd`, `Dir["/*"]`),
`system` (stub inofensivo), `fork`, `require "socket"`, `Thread.new`, `ENV` vazio.

### Aprendizados de implementação (além do spike)

- `NotImplementedError` e `LoadError` herdam de `ScriptError`, **não** de `StandardError` —
  o guest precisa de `rescue Exception` para reportá-los no envelope (spec cobre).
- Traps do wasmtime: `:interrupt` → timeout, `:out_of_fuel` → fuel, `:memory_out_of_bounds`/`linear_memory_limit_hit?`
  → memory limit, demais → `:sandbox_error`.
- `Wasmtime::WasiExit` acontece quando o guest sai sem envelope (ex.: `exit!`) → `:sandbox_error`.
- O round-trip `JSON.parse(JSON.generate(value))` no guest normaliza símbolos/objetos não
  serializáveis para o que o host efetivamente lerá.
- `store.close` no `ensure` é essencial para estabilidade de memória.

## 5. Decisões tomadas nesta fase

1. **Entrega de código**: arquivo `/work/code.rb` via `set_mapped_directory` (argv como fallback).
2. **Resultado**: `/work/out.json` (envelope JSON), com fallback de sentinela no stdout.
3. **Interrupção**: epoch como limite de wall-clock (obrigatório) + fuel como orçamento determinístico
   (opcional por config). Deadline sempre setado imediatamente antes do `invoke`.
4. **Status do Result**: `:ok`, `:error` (erro do código do usuário), `:timeout`, `:fuel_exhausted`,
   `:memory_limit` (via `linear_memory_limit_hit?`), `:sandbox_error`.
5. **Runtime compartilhado**: `Engine` + `Module` memoizados por config (mutex); `Module` compilado
   1x por processo (~15s na primeira spawn — cache em disco entra na Stage 2).
6. **Concorrência v1**: serial por processo; escala horizontal via processos. Documentado como
   limitação, Ractor fica para stage futura.

## 6. Pendências para a Stage 2

- [ ] Cache da imagem `.wasm` e do módulo compilado em disco (`Module#serialize`/`deserialize_file`)
      — elimina os ~15s de compilação fria a cada processo.
- [ ] Channel de resultado com token (ENV apagado pelo prelude) + validação de schema no host.
- [ ] Prelude de hardening: neutralizar `system`, backtick, `IO.popen`, `Kernel#open`, `ENV` após leitura.
- [ ] `Configuration` completa (perfis nomeados, `#with`, fingerprint) — hoje só o núcleo.
- [ ] Investigar: mínimo viável de `memory_size` para o boot do ruby.wasm (o default de 512MB é
      conservador); taxas de fuel por tipo de workload.
- [ ] Investigar: Ractor para paralelismo real (Engine é `frozen_shareable` no wasmtime-rb).
- [ ] Benchmark: spawn com `InstanceAllocationStrategy::Pooling`.
