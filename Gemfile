# frozen_string_literal: true

source "https://rubygems.org"

# Runtime: wasmtime embedding (engine + WASI p1)
gem "wasmtime"

# Build-time: `rbwasm` CLI to pack the ruby.wasm image
gem "ruby_wasm"

group :development, :test do
  gem "rake"
  gem "rspec"
end
