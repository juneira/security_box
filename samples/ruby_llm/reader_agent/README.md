# RubyLLM reader agent

A sample that combines [RubyLLM](https://github.com/crmne/ruby_llm) with
`security_box`: an LLM agent whose "run code" tool executes Ruby inside the
sandbox instead of on the host.

## What it demonstrates

- Exposing `SecurityBox::Sandbox#eval` to an LLM as a `RubyLLM::Tool`, so
  model-generated Ruby never runs on the host.
- **Folder mounts**: the sample registers two profiles over the same `./data`
  folder — `:read_only` (`config.mount`) and `:read_write`
  (`config.mount_rw`) — and swaps between them per chat.
- The isolation guarantees in practice: with the read-only profile the agent
  can read `/data` but every write fails with `Errno::EPERM` (enforced by
  wasmtime, the host folder is untouched); with the read-write profile the
  same write succeeds.

## How it works

1. `SecurityBox.register` defines the two mount profiles up front
   (`./data` on the host → `/data` in the sandbox, read-only and read-write).
2. `SecureExecution` is a `RubyLLM::Tool` whose `execute` spawns a sandbox
   from a profile and evals the code the model produces, returning the
   structured `Result` (`status`, `value`, `stdout`, `error`, ...) to the chat.
3. The chat asks the agent to summarize the files in `/data`, then to write a
   summary back. Under `:read_only` the write is blocked (`Errno::EPERM`);
   after switching the tool to `:read_write` the agent creates
   `/data/resume.md` and verifies it by reading it back.

## Requirements

- An `OPENROUTER_API_KEY` environment variable (the sample uses OpenRouter
  with a DeepSeek model; any RubyLLM provider works).
- The `security_box` gem with a usable sandbox image (the gem ships a prebuilt
  one; see the [root README](../../../README.md) for details).

## Running

```bash
cd samples/ruby_llm/reader_agent
bundle install
export OPENROUTER_API_KEY=...
bundle exec ruby app.rb
```

Expected behavior:

- First ask: the agent lists `/data` (contains `test.md`) and summarizes it.
- Second ask ("write this on resume.md"): blocked — `/data` is mounted
  read-only, writes fail with `Errno::EPERM`.
- Third ask ("try again") with the `:read_write` profile: the agent creates
  `/data/resume.md` and confirms the folder now contains both files.

The `data/` folder is the blast radius of the run: `resume.md` is created by
the agent. Deleting it restores the original state.

## Security notes

- The model's code runs in a fresh wasm instance per eval: no host filesystem
  (beyond explicit mounts), no network, no processes, no threads.
- **A mounted folder's content is fully readable — and with `mount_rw`
  writable — by guest code.** Only mount directories whose content you are
  willing to expose to the executed code; here the sample deliberately hands
  `./data` to the agent, including write access in the second profile.
- Timeouts, fuel, memory and output limits still apply (see the
  [root README](../../../README.md#configuration)); the sample relies on the
  defaults.
