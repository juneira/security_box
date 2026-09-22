# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "sb_rpc"
  spec.version = "0.1.0"
  spec.summary = "Host RPC bridge for security_box guest images"
  spec.description =
    "Exposes SBExt.call, a wasm import bridge the guest uses to invoke " \
    "host-registered RPC handlers. The call blocks inside the sandbox while " \
    "the host executes the handler; the request/response travel via JSON " \
    "files in /work."
  spec.authors = ["security_box"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"
  spec.files = Dir["lib/**/*.rb", "ext/**/*.{c,h,rb}"] + ["sb_rpc.gemspec"]
  spec.extensions = ["ext/sb_rpc/extconf.rb"]
end
