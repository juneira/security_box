# frozen_string_literal: true

source "https://rubygems.org"

# Runtime: embedding do wasmtime (engine + WASI p1)
gem "wasmtime"

# Build-time: CLI `rbwasm` para empacotar a imagem ruby.wasm
gem "ruby_wasm"

group :development, :test do
  gem "rake"
  gem "rspec"
end
