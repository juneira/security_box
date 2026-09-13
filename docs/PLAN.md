# Plano: `security_box` — sandbox para Ruby não confiável com ruby.wasm + wasmtime

## 1. Objetivo

Fornecer uma biblioteca Ruby (`security_box`) que executa código Ruby **não confiável** dentro de um
sandbox WebAssembly (ruby.wasm), usando a gem [`wasmtime`](https://github.com/bytecodealliance/wasmtime-rb)
como runtime embutido no processo Ruby.

Requisitos centrais:

1. **Isolamento real**: o código convidado (guest) não tem rede, não vê o filesystem do host, não
   pode criar processos e não pode escapar do runtime wasm.
2. **Limites obrigatórios**: tempo (wall-clock), CPU (fuel), memória, tamanho de saída.
3. **Configurações reutilizáveis**: um objeto de configuração imutável e barato de clonar, que pode
   ser compartilhado por vários sandboxes e usado como "perfil" nomeado.
4. **Spawnear vários sandboxes facilmente**: custo de criação previsível, pool de instâncias quentes
   e execução concorrente (o `invoke` do wasmtime-rb libera a GVL).

### Não objetivos (v1)

- Executar gems com extensões nativas arbitrárias dentro do guest (apenas gems pure-Ruby
  empacotadas na imagem).
- Threads dentro do guest (ruby.wasm/wasip1 não suporta `Thread`).
- Componentes WASI Preview 2 (usaremos Preview 1, que é o que o ruby.wasm publica hoje).
- Alta performance de *throughput* por sandbox — priorizamos isolamento e previsibilidade.

---

## 2. Como a execução funciona (fundamentos validados)

- O ruby.wasm publica binários pré-compilados por versão + perfil
  (`ruby-4.0-wasm32-unknown-wasip1-full`, `...-minimal`).
- Para rodar um script, empacotamos o runtime + stdlib + nosso script "supervisor" em um único
  `.wasm` com VFS embutido (`rbwasm pack` / `RubyWasm::Packager` + wasi-vfs). Resultado: **um
  arquivo self-contained**, sem precisar pré-abrir diretórios do host em runtime.
- O módulo expõe `_start` (WASI command). No host:

```ruby
engine   = Wasmtime::Engine.new(epoch_interruption: true, consume_fuel: true)
mod      = Wasmtime::Module.from_file(engine, image_path)   # ou .deserialize_file
linker   = Wasmtime::Linker.new(engine)
Wasmtime::WASI::P1.add_to_linker_sync(linker)

wasi = Wasmtime::WasiConfig.new
  .set_stdin_string("")                       # nunca herdar stdin do host
  .set_stdout_buffer(String.new, 1 << 20)     # saída capturada + limitada
  .set_stderr_buffer(String.new, 1 << 16)
  .set_argv(["ruby", "/src/main.rb"])
  .set_env({})

store = Wasmtime::Store.new(engine, wasi_p1_config: wasi,
                            limits: { memory_size: 64 * 1024 * 1024 })
instance = linker.instantiate(store, mod)
instance.invoke("_start")                     # libera a GVL durante a execução
```

- Limites disponíveis que usaremos: `Engine.new(consume_fuel:, epoch_interruption:, max_wasm_stack:)`,
  `Store.new(limits: { memory_size:, instances:, memories:, tables:, table_elements: })`,
  `store.set_fuel`, `store.set_epoch_deadline`, `store.linear_memory_limit_hit?`, `store.close`.
- Resultado estruturado: o guest escreve um envelope JSON em um diretório temporário **próprio do
  sandbox** montado como `/work` (read-write). O host lê `/work/out.json`. Isso evita as armadilhas
  de "forjar" delimitadores no stdout.

---

## 3. Arquitetura

```
Configuration (imutável, reutilizável)
        │  fingerprint
        ▼
   Image (build + cache) ──► arquivo .wasm  ──► Runtime (Engine + Module compilado, cache cwasm)
        │                                              │
        └────────────────► Sandbox (Store + Instance) ◄┘        Pool (instâncias quentes)
                                    │
                                 Result
```

| Camada | Responsabilidade |
|---|---|
| `Configuration` | Todos os parâmetros do sandbox. Imutável; `#with(**changes)` devolve cópia. |
| `Image` / `ImageBuilder` | Resolve/builda o `.wasm` (runtime + stdlib + gems + `guest/main.rb`), com cache por fingerprint. |
| `Runtime` | `Wasmtime::Engine` + `Module` compilado (e cache `.cwasm`) por fingerprint de config. Compartilhado entre sandboxes e threads. |
| `Sandbox` | Um `Store` + `Instance` por execução (ou por worker). Aplica WASI config, limites e deadlines. |
| `Result` | `stdout`, `stderr`, `value`, `error`, `duration_ms`, `fuel_used`, `status`. |
| `Pool` | Mantém N sandboxes quentes por perfil, devolve ao pool ou descarta (`store.close`) conforme limites. |

---

## 4. API pública (alvo)

```ruby
# Perfis nomeados e reutilizáveis
SecurityBox.register(:default) do |c|
  c.ruby_version "4.0"
  c.profile      :full                 # :full | :minimal
  c.stdlib       %w[json yaml]         # componentes extras a manter (:minimal parte vazio)
  c.gems         []                    # gems pure-Ruby allowlist, bakeadas na imagem

  c.memory_limit 64 * 1024 * 1024
  c.fuel         50_000_000
  c.timeout_ms   2_000                 # epoch interruption
  c.output_limit 1 << 20
  c.max_wasm_stack 1 << 20

  c.env          "LANG" => "C"
  c.mount        "./data" => "/data"   # read-only por padrão
  c.mount_rw     nil                   # nada gravável fora de /work

  c.mode         :oneshot              # :oneshot | :worker (fase 4)
  c.hardening    :standard             # prelude que remove APIs perigosas
end

SecurityBox.register(:lean, from: :default) do |c|
  c.profile :minimal
  c.fuel    5_000_000
  c.timeout_ms 500
end

# Uso: spawnar quantos quiser, concorrentemente
box = SecurityBox.spawn(:lean)              # ou SecurityBox.spawn(:default, fuel: 1_000)
res = box.eval(<<~RUBY)
  require "json"
  puts JSON.generate({ok: true})
  exit 0
RUBY

res.status      # => :ok | :error | :timeout | :fuel_exhausted | :memory_limit | :output_truncated
res.stdout      # => "{\"ok\":true}\n"
res.value       # => valor de retorno (JSON-serializável)
res.error       # => {class:, message:, backtrace:} quando :error
res.duration_ms # => 12.4
res.fuel_used   # => 1_284_311

# Pool para spawns frequentes
pool = SecurityBox::Pool.new(:default, size: 8, max_age: 100)
pool.checkout { |sandbox| sandbox.eval(code) }
```

`Configuration#with` nunca muta o original; `Runtime` é memoizado por fingerprint, então mil
`spawn`s da mesma config compartilham o mesmo `Engine`/`Module` compilado.

---

## 5. Isolamento e limites (matriz de defesa)

| Ameaça | Defesa |
|---|---|
| Loop infinito / CPU | `epoch_interruption` + `store.set_epoch_deadline` (wall-clock) **e** `consume_fuel` + `store.set_fuel` (orçamento determinístico) |
| Memória (bomb) | `limits: { memory_size: }` + checagem de `store.linear_memory_limit_hit?` |
| Stack overflow / recursão | `max_wasm_stack` + rescue de `SystemStackError` no guest |
| Exaustão de disco/RAM do host por muitas instâncias | `Pool` com tamanho máximo + `store.close` ao devolver/descartar |
| Rede | Nunca chamar `inherit_network`/`allow_tcp`/`allow_udp` — WASI p1 do ruby.wasm já não tem sockets |
| Filesystem do host | Nenhum diretório pré-aberto por padrão; apenas `/work` (tmpdir por sandbox) e mounts explícitos, read-only por padrão |
| Processos / `system` / backticks / fork | Inexistentes no wasip1; `hardening` prelude também remove o que sobrar |
| Flood de stdout | `set_stdout_buffer(buf, capacity)` — trunca com limite configurável |
| Vazamento de ENV/argv | `set_env({})` explícito; só variáveis permitidas |
| Fuga do runtime | Não existe syscalls nativas no wasmtime p1 sem import explícito; mantemos imports restritos ao WASI |

Hardening extra (opcional, `:standard`): um prelude carregado antes do código do usuário que:
limpa `ENV`, refina/remove `File` write ops quando não há mount RW, desabilita `Kernel#require`
dinâmico de fora da imagem, e aplica `$stdout.sync = true`. **O isolamento primário é o WASI, não o
prelude** — o prelude é defesa em profundidade.

---

## 6. Protocolo host ↔ guest

### Modo `:oneshot` (padrão, Fase 2)

1. Host cria tmpdir exclusivo do sandbox, escreve `/work/code.rb` (ou `in.json`).
2. Monta `/work` read-write via `set_mapped_directory(tmpdir, "/work", :read_write)`.
3. Instancia e invoca `_start`; guest (`lib/security_box/guest/main.rb`):
   - lê `/work/code.rb`, avalia em um `begin/rescue` com `$stdout` redirecionado,
   - serializa envelope `{ok, value, error, backtrace, duration_ms}` em `/work/out.json`,
   - sai com `exit 0` (mesmo em erro de usuário — erro de usuário é *resultado*, não falha do sandbox).
4. Host lê `/work/out.json`, aplica `store.close`, remove tmpdir.

Vantagem: um processo wasm novo por execução ⇒ zero estado residual entre execuções, sem
necessidade de "reset".

### Modo `:worker` (Fase 4, somente se o benchmark justificar)

Instância longa-viva que processa vários pedidos, para amortizar o custo de instanciação.
Canais candidatos, em ordem de preferência a validar no spike:

1. **FIFOs** apontados por `set_stdin_file` / `set_stdout_file` (host escreve pedidos, guest lê
   bloqueante; host lê respostas de outra thread — `invoke` libera a GVL).
2. **Arquivos com duplo buffer** em `/work` + polling curto (fallback simples e portável).

Só adotaremos se o custo de instanciação medido no M0 for alto (ex.: > 10 ms). Caso contrário,
o modo `:oneshot` + pool de pré-aquecimento com `InstanceAllocationStrategy::Pooling` resolve.

---

## 7. Configurações reutilizáveis (detalhes de design)

- `Configuration` é `Data`/frozen; `#with` usa merge raso por grupo (`image:`, `limits:`,
  `wasi:`, `runtime:`), e o fingerprint é `Digest::SHA256` do hash normalizado.
- Dois níveis de cache derivados do fingerprint:
  - `~/.cache/security_box/images/<sha>.wasm` — imagem empacotada;
  - `~/.cache/security_box/modules/<sha>-<precompile_key>.cwasm` — módulo compilado
    (`Module#serialize` + `deserialize_file`, chave de `engine.precompile_compatibility_key`).
- `Runtime` guarda `Engine` + `Module` em um registry global (`SecurityBox::Runtime.registry`),
  protegido por mutex; `Engine`/`Module` são thread-safe e reutilizáveis.
- `spawn` nunca builda nada em runtime: se o fingerprint não estiver em cache e o build estiver
  desabilitado ( produção), levanta `SecurityBox::ImageMissing`. Build é passo explícito
  (`rake security_box:build` / `SecurityBox.build_all!`).
- Perfis nomeados permitem `SecurityBox.spawn(:lean)`, `SecurityBox.spawn(:lean, fuel: 1000)`, e
  `SecurityBox::Pool.new(:lean)` — todos compartilhando a mesma imagem/módulo quando possível.

---

## 8. Estrutura de arquivos

```
lib/security_box.rb                       # API pública: register/spawn/build_all!
lib/security_box/configuration.rb         # imutável + #with + fingerprint
lib/security_box/registry.rb              # perfis nomeados + runtime/image caches
lib/security_box/image.rb                 # resolução + fingerprint + cache
lib/security_box/image_builder.rb         # rbwasm pack / RubyWasm::Packager
lib/security_box/runtime.rb               # Engine + Module (+ cwasm cache)
lib/security_box/sandbox.rb               # Store/Instance, WASI config, limites, eval
lib/security_box/result.rb                # envelope de resultado
lib/security_box/errors.rb                # SecurityBox::Error, Timeout, FuelExhausted, ...
lib/security_box/pool.rb                  # pool de sandboxes quentes
lib/security_box/guest/main.rb            # script empacotado (entrypoint _start)
lib/security_box/guest/prelude.rb         # hardening opcional
lib/security_box/version.rb
exe/security_box                          # CLI: security_box eval / build / doctor
security_box.gemspec                      # deps: wasmtime (runtime), ruby_wasm (build, opcional)
spec/…                                    # unit + integração + matriz de escapes + benchmarks
```

Dependências: `wasmtime` (runtime, gem pré-compilada; adicionar plataformas ao lock:
`x86_64-linux`, `aarch64-linux`, `arm64-darwin`, `x86_64-darwin`), `ruby_wasm` (somente build),
`json` (stdlib).

---

## 9. Fases

### M0 — Spike de viabilidade (1–2 dias)
- Baixar `ruby-4.0-wasm32-unknown-wasip1-full`, empacotar `guest/main.rb` com `rbwasm pack`.
- Rodar via wasmtime-rb: `puts` básico, captura de stdout, JSON requerido de dentro do wasm.
- Validar interrupção: loop infinito morto por `epoch`, e por `fuel`.
- Medir: tamanho da imagem, tempo de `_start` frio/quente, pico de memória por instância.
- **Critério de saída**: números documentados em `docs/benchmarks.md` + decisão `:oneshot` vs `:worker`.

### M1 — Núcleo
`Configuration`, `Runtime`, `Sandbox#eval` one-shot, `Result`, errors, API `register/spawn`.
Testes de unidade + integração.

### M2 — Isolamento e limites
Fuel/epoch/memory/output-limit, mounts read-only, env saneada, `/work` por sandbox, prelude de
hardening, `store.close`, tradução de traps (`Wasmtime::Trap`) para `Result#status`.

### M3 — Imagens e cache
`ImageBuilder` (versão, perfil, stdlib components, gems allowlist), fingerprint, cache em disco,
cache de módulo compilado, rake tasks, `security_box build`.

### M4 — Pool e concorrência
`Pool` com tamanho/limites, pré-aquecimento, métricas (spawns, tempo médio, descartes), teste de
carga concorrente; spike do modo `:worker` se justificado pelo M0.

### M5 — DX e operação
CLI (`eval`, `build`, `doctor`), logs estruturados, telemetria opcional, gem release, docs
(`docs/SECURITY.md` com o modelo de ameaças), benchmarks no CI.

---

## 10. Testes

- **Matriz de escapes** (cada item vira um teste que deve resultar em `Result`, nunca em quebra do
  host): `loop {}`, `until false`, `"a" * 10**12`, `eval("`ls`")`, `system("ls")`, `fork`,
  `File.write("/etc/passwd")`, `Dir["/"]`, `ENV`, `require "socket"`, `require "open-uri"`,
  `Thread.new`, `exit!`, `at_exit`, `Process.kill`, `Random` gigante, `Marshal.load` hostil,
  recursão infinita, `puts "x" * 10**9`, `String#*`, `Regexp` catastrófico, `$0`/`__FILE__`.
- **Limites**: cada limite estourado produz o `status` correto e libera recursos (`store.close`).
- **Configs**: `#with` não muta; fingerprints iguais reusam Runtime; configs diferentes isoladas;
  `spawn` concorrente em N threads sem vazamento de memória.
- **Benchmarks**: latência de spawn p50/p99, throughput, memória por instância — trilho de guarda
  no CI (falha se regressar > X%).

---

## 11. Riscos e perguntas abertas

1. **Custo de instanciação do ruby.wasm** (imagem "full" é grande) — define se precisamos do modo
   worker. Mitigação: módulo pré-compilado + pooling allocator + pool de instâncias.
2. **Tamanho da imagem** pode inviabilizar cache em containers pequenos — mitigar com perfil
   `:minimal` + `stdlib` allowlist e remoção de componentes não usados.
3. **FIFOs** no modo worker podem travar na abertura em algumas plataformas; Windows é fora do
   escopo do worker mode.
4. **Fidelidade da versão**: o Ruby do guest é o do ruby.wasm (4.0/3.4), não necessariamente o do
   host — documentar claramente e permitir configurar por perfil.
5. **Serialização do valor de retorno**: JSON é seguro mas limitado (objetos complexos viram
   `String`/`nil`). Alternativa: `Marshal` para um arquivo em `/work` — mas **nunca** desserializar
   no host; manter JSON no v1.
6. **Traps do wasmtime** (`Wasmtime::Trap`) precisam ser mapeados para `status` sem vazar detalhes
   internos do runtime em mensagens de erro.
7. **Observabilidade**: como correlacionar execuções (request id) — injetar via env do guest e
   ecoar no envelope.
