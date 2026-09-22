# Loaded by `require "sb_rpc"` inside the security_box guest image.
#
# The extension is statically linked into the ruby.wasm binary; requiring
# the .so feature name triggers its Init_sb_rpc hook through the static
# extension registry.
require "sb_rpc.so"
