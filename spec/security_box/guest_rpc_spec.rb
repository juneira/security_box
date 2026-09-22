# frozen_string_literal: true

require "spec_helper"

# Integration suite for the host RPC channel (stage 6) against the real
# image: guest SB.call -> wasm import -> GuestRpc closure -> handlers.
RSpec.describe "guest RPC (SB.call)" do
  subject(:sandbox) { SecurityBox::Sandbox.new }

  # Integration suite against the real ruby.wasm: each eval spawns a sandbox.
  # Per-test timeout so a failing kill doesn't hang the suite.
  around do |example|
    Timeout.timeout(30) { example.run }
  end

  it "round-trips a blocking call (kwargs and hash forms)" do
    result = sandbox.eval(
      'SB.call("double", n: 21) + SB.call("double", { "n" => 3 })',
      rpcs: { "double" => ->(args) { args["n"] * 2 } }
    )

    expect(result).to be_ok
    expect(result.value).to eq(48)
  end

  it "delivers JSON-parsed args (string keys) to the handler" do
    seen = nil
    sandbox.eval('SB.call("capture", { symbol: 1 })',
                 rpcs: { "capture" => ->(args) { seen = args; args } })

    expect(seen).to eq({ "symbol" => 1 })
  end

  it "blocks: the guest observes wall-clock time inside the call" do
    result = sandbox.eval(
      'SB.call("slow")',
      rpcs: { "slow" => ->(_args) { sleep(0.3); 1 } }
    )

    expect(result).to be_ok
    expect(result.duration_ms).to be >= 300
  end

  it "maps handler failures to guest-rescuable SB::ToolError (no backtrace)" do
    result = sandbox.eval(
      'begin
         SB.call("boom")
         "no-raise"
       rescue SB::ToolError => e
         "#{e.class}: #{e.message}"
       end',
      rpcs: { "boom" => ->(_args) { raise ArgumentError, "handler blew up" } }
    )

    expect(result).to be_ok
    expect(result.value).to eq("SB::ToolError: handler blew up")
    expect(result.rpcs.last["error"]["message"]).to eq("handler blew up")
    expect(result.rpcs.last["error"]).not_to have_key("backtrace")
  end

  it "maps unknown names to guest-rescuable SB::UnknownTool" do
    result = sandbox.eval(
      'begin
         SB.call("missing_tool")
         "no-raise"
       rescue SB::UnknownTool => e
         "#{e.class}: #{e.message}"
       end',
      rpcs: { "echo" => ->(args) { args } }
    )

    expect(result).to be_ok
    expect(result.value).to eq("SB::UnknownTool: unknown rpc: missing_tool")
  end

  it "reports a clean error when no handlers are configured" do
    result = sandbox.eval(
      'begin
         SB.call("echo")
         "no-raise"
       rescue SB::UnknownTool => e
         "#{e.class}: #{e.message}"
       end'
    )

    expect(result).to be_ok
    expect(result.value).to eq("SB::UnknownTool: no RPC handlers are configured for this sandbox")
  end

  it "attaches the call transcript to the result" do
    result = sandbox.eval(
      '[SB.call("double", n: 2), SB.call("double", n: 3)]',
      rpcs: { "double" => ->(args) { args["n"] * 2 } }
    )

    expect(result).to be_ok
    expect(result.rpcs).to eq([
                                { "name" => "double", "args" => { "n" => 2 }, "ok" => true, "result" => 4 },
                                { "name" => "double", "args" => { "n" => 3 }, "ok" => true, "result" => 6 }
                              ])
    expect(result.rpcs).to be_frozen
  end

  it "returns nil rpcs when none were configured" do
    expect(sandbox.eval("1 + 1").rpcs).to be_nil
  end

  it "serializes non-JSON handler results as inspect strings" do
    result = sandbox.eval('SB.call("object")',
                          rpcs: { "object" => ->(_args) { Object.new } })

    expect(result).to be_ok
    expect(result.value).to be_a(String)
    expect(result.rpcs.last["result"]).to be_a(String)
  end

  it "truncates oversized handler results to a guest-rescuable error" do
    result = sandbox.eval(
      'begin
         SB.call("big")
         "no-raise"
       rescue SB::ToolError => e
         e.message.include?("too large") ? "too-large" : e.message
       end',
      rpcs: { "big" => ->(_args) { "x" * (SecurityBox::GuestRpc::RESULT_LIMIT + 1024) } }
    )

    expect(result).to be_ok
    expect(result.value).to eq("too-large")
    expect(result.rpcs.last["ok"]).to be(false)
  end

  it "serializes non-JSON-serializable args as inspect strings (json fallback)" do
    result = sandbox.eval('SB.call("echo", Object.new)',
                          rpcs: { "echo" => ->(args) { args } })

    expect(result).to be_ok
    expect(result.value).to be_a(String)
    expect(result.value).to include("Object")
  end

  it "honors the per-call :rpcs override (replaces, like env:)" do
    result = sandbox.eval(
      'SB.call("square", n: 7)',
      rpcs: { "square" => ->(args) { args["n"] * args["n"] } }
    )

    expect(result).to be_ok
    expect(result.value).to eq(49)
  end

  it "maps the handler result back even when it raises SystemStackError-like exceptions" do
    result = sandbox.eval(
      'begin
         SB.call("recursion")
       rescue SB::ToolError
         "rescued"
       end',
      rpcs: { "recursion" => ->(_args) { raise SystemStackError, "deep" } }
    )

    expect(result).to be_ok
    expect(result.value).to eq("rescued")
  end
end
