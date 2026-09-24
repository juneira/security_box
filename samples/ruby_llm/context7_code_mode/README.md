# RubyLLM code-mode agent (Context7 via sandbox RPC)

A sample that combines [RubyLLM](https://github.com/crmne/ruby_llm) with the
`security_box` host RPC (stage 6) to build a **code mode** agent: the LLM does
not call MCP tools directly — it writes Ruby programs that run inside the
sandbox, and those programs reach the Context7 documentation MCP server
through `SB.call`.

## What it demonstrates

- **Code mode end to end**: model-generated Ruby executed in a fresh wasm
  instance per eval, with `SB.call("context7.<tool>", args)` as a plain,
  blocking function call from the guest to host-registered handlers.
- **The host RPC layer as an MCP bridge**: the handlers registered with
  `c.rpc "context7.resolve-library-id" => ->(args) { ... }` and
  `c.rpc "context7.query-docs" => ...` proxy a real MCP server over
  streamable HTTP (`https://mcp.context7.com/mcp`) through
  `context7_client.rb`, a minimal MCP client written with the Ruby standard
  library only (initialize handshake, `tools/list`, `tools/call`, SSE
  parsing).
- **Secret isolation by construction**: the Context7 API key lives in the
  host closure only. The guest has no network, no `ENV` and no filesystem
  access to it; it can only invoke the registered names with JSON args.
- **Agent debugging surface**: every eval prints the sandbox `Result` and
  the per-call RPC transcript (`Result#rpcs`), and the tool feeds a
  summarized version back to the model — failed RPCs arrive as rescuable
  `SB::ToolError`s, so the model can correct its own arguments and retry
  (watch it do exactly that in the demo output).

## Architecture

```
LLM (RubyLLM chat)
  └─ tool: code_mode(code)
       └─ SecurityBox.spawn(:coder).eval(code)        # fresh wasm per eval
            └─ SB.call("context7.resolve-library-id", ...)
               └─ host RPC handler (allowlist)
                    └─ Context7Client (host, stdlib only, holds the API key)
                         └─ https://mcp.context7.com/mcp (streamable HTTP)
```

Files:

| File | Role |
|---|---|
| `context7_client.rb` | Minimal MCP client: JSON-RPC over streamable HTTP + SSE, bearer auth, session header |
| `sandbox_profile.rb` | Registers the `:coder` profile: RPC handlers → MCP tools, plus limits |
| `smoke.rb` | No-LLM check of the whole RPC↔MCP wiring with a fixed guest program |
| `app.rb` | The RubyLLM agent: system prompt, `code_mode` tool, demo question |

## Requirements

- `CONTEXT7_API_KEY` — Context7 API key (create one in the
  [Context7 dashboard](https://context7.com/dashboard)).
- `OPENROUTER_API_KEY` — the sample uses OpenRouter with a DeepSeek model;
  any RubyLLM provider works (override the model with `MODEL`).
- The `security_box` gem with a usable sandbox image (the gem ships a
  prebuilt one; see the [root README](../../../README.md)).

## Running

Verify the RPC↔MCP wiring first (no model tokens spent):

```bash
cd samples/ruby_llm/context7_code_mode
bundle install
export CONTEXT7_API_KEY=...
bundle exec ruby smoke.rb
```

Then run the agent:

```bash
export OPENROUTER_API_KEY=...
bundle exec ruby app.rb
```

Expected behavior:

- `smoke.rb` performs the MCP handshake, lists the server tools, then evals
  a guest program that resolves "RubyLLM" to a Context7 library id, queries
  the docs and returns a structured summary — all through `SB.call`.
- `app.rb` asks the model to look up RubyLLM on Context7 and answer how to
  define a custom tool, with a code example from the fetched docs. The
  model writes Ruby, the sandbox runs it, and the final answer cites only
  the fetched documentation.

## Security notes

- **The API key never crosses the sandbox boundary.** It is read from the
  environment on the host and kept inside the client/handler closure.
- **Allowlist, not general network access**: guest code can only call the
  RPC names registered in `sandbox_profile.rb`; anything else raises
  `SB::UnknownTool`. There is no way to point `SB.call` at an arbitrary
  URL.
- **Standard sandbox limits still apply** (see the
  [root README](../../../README.md#configuration)): at most 1000 RPC calls
  per eval, 1 MiB per RPC response (the profile clamps the `tokens`
  argument to keep Context7 responses well below it), fuel and wall-clock
  caps per eval. Note that `timeout_ms` covers the whole eval including
  handler network time (stage 6), which is why the profile uses 60s.
- **Handler errors are sanitized**: the guest sees `class` + `message`
  only — no backtraces, no host paths, no key material.
