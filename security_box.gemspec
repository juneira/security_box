# frozen_string_literal: true

require_relative "lib/security_box/version"

Gem::Specification.new do |spec|
  spec.name = "security_box"
  spec.version = SecurityBox::VERSION
  spec.authors = ["Marcelo Junior"]
  spec.email = ["marcelo.jr63@gmail.com"]

  spec.summary = "Run untrusted Ruby code inside a WebAssembly sandbox"
  spec.description =
    "SecurityBox runs untrusted Ruby code inside a ruby.wasm (wasm32-unknown-wasip1) " \
    "module via the wasmtime gem. The guest has no filesystem, network, processes, " \
    "threads or sockets, and the host enforces CPU (fuel), wall-clock, memory and " \
    "output-size limits, always receiving a structured Result back."
  spec.homepage = "https://github.com/juneira/security_box"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  # The packed ruby.wasm image (lib/security_box/assets/security_box.wasm) is
  # gitignored, so it is only present after `rake security_box:build_image`.
  # `rake build`/`rake release` depend on that task, ensuring the gem always
  # ships a fresh image.
  spec.files = Dir["lib/**/*"] +
               Dir["README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "wasmtime"
end