#include <ruby.h>
#include <stdint.h>

/*
 * Host bridge for security_box RPC.
 *
 * sb_rpc_call is resolved as a wasm import by the host
 * (Wasmtime::Linker#func_new, module "sb", function "call"). The guest
 * blocks inside this call while the host executes the registered handler;
 * the host returns 0 on success (any other value signals a transport
 * failure). The request/response payload travels via /work JSON files
 * written/read by the guest-side Ruby wrapper (sb_rpc.rb in the image),
 * keeping this C code free of any protocol knowledge.
 */
__attribute__((import_module("sb"), import_name("call")))
extern int32_t sb_rpc_call(void);

static VALUE
sb_call(VALUE self)
{
    return INT2NUM(sb_rpc_call());
}

void
Init_sb_rpc(void)
{
    VALUE mSBExt = rb_define_module("SBExt");
    rb_define_singleton_method(mSBExt, "call", sb_call, 0);
}
