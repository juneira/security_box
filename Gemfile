# frozen_string_literal: true

source "https://rubygems.org"

# Runtime: wasmtime embedding (engine + WASI p1)
gem "wasmtime"

group :development do
  # Build-time: `rbwasm` CLI to pack the ruby.wasm image (not a runtime dep)
  gem "ruby_wasm"
end

group :development, :test do
  gem "rake"
  gem "rspec"
end
