# frozen_string_literal: true

require_relative "context7_client"

# Registers the :coder security_box profile shared by smoke.rb and app.rb.
#
# The host RPC handlers proxy the Context7 MCP tools, so guest code can
# reach them with SB.call("context7.<tool>", ...) — see lib/security_box/
# guest/rpc.rb for the guest side. Handler raises become guest-rescuable
# SB::ToolError values; the API key stays in the host closure.
module SandboxProfile
  # Keeps one RPC response well below the security_box per-call result
  # limit (1 MiB): query-docs accepts a free-form `tokens` cap.
  MAX_RPC_TOKENS = 5_000

  def self.register!(client)
    SecurityBox.register(:coder) do |c|
      c.rpc "context7.resolve-library-id" =>
            ->(args) { client.call_tool!("resolve-library-id", args) }
      c.rpc "context7.query-docs" =>
            ->(args) { client.call_tool!("query-docs", clamp_tokens(args)) }
      # The epoch deadline covers the whole eval: guest boot + compute +
      # handler time (network included, stage 6 Q8). query-docs can take
      # several seconds per call, so leave room for a few of them.
      c.timeout_ms 60_000
      c.fuel_ms 1_000
    end
  end

  def self.clamp_tokens(args)
    tokens = args["tokens"].to_i
    tokens = MAX_RPC_TOKENS if tokens <= 0 || tokens > MAX_RPC_TOKENS
    args.merge("tokens" => tokens)
  end
end
