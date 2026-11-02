# RSpec inside the sandbox

A sample that runs a real RSpec suite inside a `security_box` sandbox. The
sandbox image bundles RSpec; this sample keeps a small library and its spec in
`ruby_src/`, mounts that folder read-only at `/ruby_src` and runs the existing
suite with the sandbox's writable `/work` directory as cwd.

## What it demonstrates

- **RSpec as a guest gem**: the image ships `rspec ~> 3.13`, so untrusted or
  model-generated code can run tests without access to the host.
- **Read-only source mount + `/work` cwd**: `ruby_src/` is mounted at
  `/ruby_src`; the guest runs the suite that already exists there, with `/work`
  as the working directory. No files are generated or modified.
- **`SB.run_rspec(*args, chdir: "/work")`**: lazy-loads RSpec, sets `HOME` and
  cwd, and returns the RSpec exit status (`0` = all examples passed) instead of
  exiting the guest.
- **Failure reporting**: the suite includes one deliberately failing example, so
  the run shows how failures reach the caller — `status: ok` (the guest returned
  normally), `value: 1` (RSpec's exit status) and the formatted failure in
  `Result#stdout`.

## Files

| File | Role |
|---|---|
| `run.rb` | Registers the `:rspec` profile, mounts `ruby_src/` and runs its suite |
| `ruby_src/calculator.rb` | Small library under test |
| `ruby_src/spec/calculator_spec.rb` | Existing suite (includes one deliberately failing example) |

## Requirements

- Ruby >= 4.0 and this repository checkout with a built sandbox image. The
  Gemfile uses `gem "security_box", path: "../.."`, so the sample runs against
  the local library and its `lib/security_box/assets/security_box.wasm` image.
- If the image is missing, build it from the repository root:

  ```bash
  bundle exec rake security_box:build_image
  ```

  The image must be the one built from this checkout — it is the image that
  bundles RSpec.

## Running

```bash
cd samples/rspec_sandbox
bundle install
bundle exec ruby run.rb
```

Expected behavior:

1. The existing `ruby_src` suite runs with `/work` as cwd and returns
   `status: ok`, `value: 1`, with `4 examples, 1 failure` in stdout.
2. The stdout includes RSpec's formatted failure block:

   ```text
   1) Calculator a deliberately failing example shows how RSpec failures are reported
      Failure/Error: expect(Calculator.add(2, 3)).to eq(6)

        expected: 6
             got: 5
   ```

   Note that the sandbox `status` is still `:ok`: the guest returned normally,
   and `1` is RSpec's exit status (the value of the eval).

## Notes and limits

- `/work` is the sandbox's own writable tmpdir, used here as the suite's cwd.
  It cannot be used as a mount target, so the sources are mounted elsewhere
  (here `/ruby_src`).
- Pass `-I /ruby_src` (or use `--require`) so specs can `require` the library;
  `SB.run_rspec` already uses `/work` as cwd by default.
- Specs need a larger `timeout_ms`/`fuel_ms` than trivial evals; this sample
  uses 30s and 20s.
- The guest has no process APIs, so RSpec features that spawn processes
  (external formatters, `--bisect`-style workflows) are unavailable.
- The image bundles RSpec only — gems from the mounted sources are not
  installed. Specs that require other gems fail with `LoadError`.