# frozen_string_literal: true

# No-LLM check of the whole RPC<->MCP wiring:
#
#   guest code -> SB.call -> security_box host RPC handlers -> Context7Client
#   -> https://mcp.context7.com/mcp -> back into the guest as a value
#
# Runs a fixed guest program (the same shape the LLM writes in app.rb) and
# prints the eval result plus the RPC transcript. Run this before app.rb to
# verify the API key, network path and sandbox profile without spending
# model tokens:
#
#   CONTEXT7_API_KEY=... bundle exec ruby smoke.rb [library name]

require "security_box"
require_relative "context7_client"
require_relative "sandbox_profile"

client = Context7Client.new(api_key: ENV.fetch("CONTEXT7_API_KEY"))

puts "== MCP handshake"
info = client.initialize!
puts "server: #{info.dig("serverInfo", "name")} #{info.dig("serverInfo", "version")}"
puts "tools:  #{client.list_tools.map { |t| t["name"] }.join(", ")}"

SandboxProfile.register!(client)

library = ARGV[0] || "RubyLLM"
code = <<~CODE
  listing = SB.call("context7.resolve-library-id",
                    query: "defining custom tools",
                    libraryName: #{library.inspect})

  # The listing is plain text: extract the first /org/project-style id.
  # (\\w is doubled for the unquoted heredoc: the guest must see \w.)
  id = listing.scan(%r{/[\\w.-]+/[\\w.-]+}).first
  raise "no library id found in listing:\\n\#{listing[0, 400]}" if id.nil?

  docs = SB.call("context7.query-docs",
                 libraryId: id,
                 query: "how to define a custom tool",
                 tokens: 3000)

  {
    library_id: id,
    listing_chars: listing.length,
    docs_chars: docs.length,
    docs_preview: docs.lines.first(6).join
  }
CODE

puts "\n== sandbox eval"
result = SecurityBox.spawn(:coder).eval(code)

puts "status:    #{result.status}"
puts "duration:  #{result.duration_ms}ms"
puts "value:     #{result.value.inspect}"
puts "stdout:    #{result.stdout}"
puts "stderr:    #{result.stderr}" unless result.stderr.to_s.empty?
puts "error:     #{result.error.inspect}" if result.error

puts "\n== RPC transcript (Result#rpcs)"
Array(result.rpcs).each do |call|
  outcome = call["ok"] ? "ok" : "FAILED: #{call.dig('error', 'message')}"
  puts "  #{call['name']} #{call['args'].inspect} -> #{outcome}"
end

abort "smoke FAILED (status #{result.status})" unless result.ok?
puts "\nsmoke PASSED"
