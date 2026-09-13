# security_box

A secure sandbox to run untrusted Ruby code, built on top of
[ruby.wasm](https://github.com/ruby/ruby.wasm) and the
[wasmtime](https://github.com/bytecodealliance/wasmtime-rb) gem.

Guest code runs inside a WebAssembly module compiled to `wasm32-unknown-wasip1`, so it has
no access to the host filesystem, no network, no processes, no threads and no sockets.
The host controls CPU (fuel), wall-clock time (epoch interruption), memory and output size,
and always gets a structured `Result` back — even when the guest code raises, times out or
tries to escape.

## How it works

1. A `ruby.wasm` image is packed with the Ruby runtime + stdlib + a small guest
   entrypoint (`lib/security_box/guest/main.rb`).
2. On every `#eval`, the host creates an exclusive tmpdir, writes the user code to it, and
   mounts it read-write as `/work` inside the sandbox.
3. A fresh wasm instance boots, evaluates the code and serializes a JSON envelope to
   `/work/out.json`.
4. The host reads the envelope, maps any wasmtime trap to a `Result` status, closes the
   store and discards the tmpdir.

One wasm process per `#eval` means zero residual state between executions.

## Requirements

- Ruby >= 4.0 (host)
- `wasmtime` gem (runtime) and `ruby_wasm` gem (build-time only) — see `Gemfile`

## Setup

Add to your `Gemfile`:

```ruby
gem "security_box", path: "." # or your gem source
```

Then build the sandbox image (downloads `ruby-4.0-wasm32-unknown-wasip1-full` and packs it
with the guest script):

```bash
bundle install
bundle exec rake security_box:build_image
```

The image is written to `build/security_box.wasm` (about 110MB). It is not committed to
git — repack it after changing `lib/security_box/guest/*.rb`.

## Usage

### Quick start

```ruby
require "security_box"

result = SecurityBox.eval("puts 'hello'; 40 + 2")

result.status    # => :ok
result.value     # => 42
result.stdout    # => "hello\n"
result.fuel_used # => > 0
result.duration_ms # => 257.0 (approx; dominated by the ruby.wasm boot)
```

### Multiple evaluations on the same sandbox

```ruby
sandbox = SecurityBox::Sandbox.new
sandbox.eval("1 + 1").value # => 2
sandbox.eval("3 * 3").value # => 9
```

### Per-call limits

Options can be passed per call (derived from the configuration without mutating it):
`timeout_ms`, `fuel`, `memory_size`, `stdout_limit`, `stderr_limit`.

```ruby
# Wall-clock limit via epoch interruption
SecurityBox.eval("while true; end", timeout_ms: 500).status # => :timeout

# Deterministic CPU budget
SecurityBox.eval("while true; end", fuel: 1_000_000).status # => :fuel_exhausted

# Memory limit
SecurityBox.eval(
  "a = []; loop { a << ('x' * 1024) }",
  memory_size: 128 * 1024 * 1024,
  timeout_ms: 15_000
).status # => :memory_limit

# Output truncation
SecurityBox.eval('1000.times { print "x" * 1000 }', stdout_limit: 4096).stdout.bytesize # => <= 4096
```

### Errors from guest code

Exceptions raised by guest code are a *result*, not a sandbox failure:

```ruby
result = SecurityBox.eval('raise ArgumentError, "boom"')

result.status           # => :error
result.error["class"]   # => "ArgumentError"
result.error["message"] # => "boom"
```

### Configuration

`SecurityBox::Configuration` is immutable; use `.build` to create and `#with` to derive:

```ruby
config = SecurityBox::Configuration.build(
  fuel: 10_000_000_000,             # deterministic CPU budget
  timeout_ms: 2_000,                # wall-clock limit (epoch interruption)
  memory_size: 512 * 1024 * 1024,   # wasm linear memory limit
  stdout_limit: 1 << 20,            # stdout capture capacity in bytes
  stderr_limit: 1 << 16,            # stderr capture capacity in bytes
  epoch_interval_ms: 25,            # epoch timer granularity
  env: { "LANG" => "C" }            # guest environment (empty by default)
)

lean = config.with(timeout_ms: 500, fuel: 5_000_000)
sandbox = SecurityBox::Sandbox.new(lean)
```

### Result statuses

| Status | Meaning |
|---|---|
| `:ok` | guest code ran and returned a value |
| `:error` | guest code raised an exception (see `#error`) |
| `:timeout` | interrupted by the epoch deadline (wall clock) |
| `:fuel_exhausted` | CPU budget exhausted |
| `:memory_limit` | exceeded the store `memory_size` |
| `:sandbox_error` | sandbox failure (unexpected trap, missing/invalid envelope) |

Values are JSON-serialized; non-serializable objects are returned as their `inspect`
string.

## Isolation guarantees

| Probe inside the guest | Result |
|---|---|
| `File.write("/etc/passwd", ...)` | `Errno::ENOENT` (guest does not see the host FS) |
| `Dir["/*"]` | `[]` (empty root) |
| `system("ls")` / backticks / `IO.popen` | no-op stubs / `ArgumentError` (nothing executes) |
| `fork` | `NotImplementedError` |
| `Thread.new` | `NotImplementedError` (WASI p1 has no threads) |
| `require "socket"` | `LoadError` (no network) |
| `ENV` | `{}` (sanitized) |
| infinite loop | killed by epoch deadline or fuel budget |

Notes:

- The guest Ruby version is the one from ruby.wasm (4.0), not necessarily the host's.
- Concurrency: `invoke` holds the GVL, so executions serialize per host process. Scale
  horizontally with multiple processes (e.g., Puma workers); a stuck guest still can't
  hang the process thanks to the epoch deadline.

## Running the tests

```bash
bundle exec rspec spec/
```

The integration suite runs against the real ruby.wasm image. If `build/security_box.wasm`
is missing, the suite builds it automatically before running (this may take a few minutes
the first time).

## Learning spike

`bin/spike.rb` validates the feasibility questions (Q1–Q9) against the built image and
prints a timing report:

```bash
bundle exec ruby bin/spike.rb
```

## Documentation

- `docs/PLAN.md` — architecture, roadmap and threat model
- `docs/plan/stages/stage_1.md` — stage 1 findings and measured numbers
