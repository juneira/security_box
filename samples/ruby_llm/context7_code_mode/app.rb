# frozen_string_literal: true

# RubyLLM "code mode" demo: the model never calls the Context7 MCP server
# itself. It writes Ruby programs and runs them in the security_box sandbox
# through the code_mode tool; inside the sandbox, SB.call reaches the
# host-registered RPC handlers (see sandbox_profile.rb), which perform the
# actual MCP requests with the API key. The key never crosses the sandbox
# boundary, and the model can only reach the names on the allowlist.
#
#   LLM -> code_mode(code) -> SecurityBox sandbox (wasm, no network)
#             SB.call("context7.*", args)
#               -> host RPC handler -> Context7Client -> context7 MCP
#
# Usage: CONTEXT7_API_KEY=... OPENROUTER_API_KEY=... bundle exec ruby app.rb

require "ruby_llm"
require "security_box"
require_relative "context7_client"
require_relative "sandbox_profile"

RubyLLM.configure do |config|
  config.openrouter_api_key = ENV.fetch("OPENROUTER_API_KEY")
end

client = Context7Client.new(api_key: ENV.fetch("CONTEXT7_API_KEY"))
client.initialize!
SandboxProfile.register!(client)

# Tool exposed to the model: runs its generated Ruby inside the sandbox and
# reports the structured Result back, including the RPC transcript so the
# model can see what its calls returned.
class CodeMode < RubyLLM::Tool
  TOOL_DESCRIPTION = <<~DESC
    Runs a Ruby program inside a secure WebAssembly sandbox and returns the result.
    The sandbox has NO network, NO environment variables and NO host filesystem: the
    only way to reach the outside world is SB.call(name, args) — a plain, blocking
    function call to a host-registered RPC.

    Available RPCs (Context7 documentation lookup, MCP):
      SB.call("context7.resolve-library-id", query: "...", libraryName: "Next.js")
        -> String listing matching libraries; each entry contains a
           "Context7-compatible library ID" such as /org/project, needed by query-docs.
      SB.call("context7.query-docs", libraryId: "/org/project", query: "one focused topic", tokens: 3000)
        -> String with the documentation text for that topic (tokens caps the size, max 5000).

    Notes:
    - Arguments may be passed keyword-style or as a plain Hash; all values must be
      JSON-serializable. Results come back as plain Strings (the raw MCP text content).
    - Failed calls raise SB::ToolError (SB::UnknownTool for an unregistered name).
      Rescue them, adjust the arguments, and retry.
    - The sandbox runs Ruby 4.0 with the standard library only (json, csv, time, ...):
      no gems, no require of external libraries.
  DESC

  parameter :code,
            type: :string,
            description: "Ruby source code to execute. Use SB.call as described to reach the host services."

  def initialize
    @box = SecurityBox.spawn(:coder)
  end

  def execute(code:)
    puts "=> sandbox eval:\n#{code}"
    result = @box.eval(code)
    puts "<= #{result.status} (#{result.duration_ms.round}ms)"

    {
      status: result.status.to_s,
      value: truncate(result.value.inspect),
      stdout: truncate(result.stdout),
      stderr: truncate(result.stderr),
      error: result.error && result.error.slice("class", "message"),
      rpc_calls: Array(result.rpcs).map { |call| rpc_summary(call) }
    }
  end

  private

  # Long payloads are truncated to keep the tool result readable by the model.
  def truncate(text, limit = 4_000)
    text = text.to_s
    return text if text.length <= limit

    "#{text[0, limit]}...[truncated, #{text.length} bytes total]"
  end

  def rpc_summary(call)
    summary = call.slice("name", "args", "ok")
    if call["ok"]
      summary["result"] = truncate(call["result"].is_a?(String) ? call["result"] : call["result"].inspect, 2_000)
    else
      summary["error"] = call["error"]
    end
    summary
  end
end

SYSTEM_PROMPT = <<~PROMPT
  You are a documentation-research agent working in "code mode": you do not call
  APIs directly. Instead you write small Ruby programs and run them in a secure
  sandbox via the code_mode tool. Inside the sandbox there is no network; your
  programs reach the outside world only through SB.call(name, args), a blocking
  call to host-registered RPCs (documented in the tool description).

  Write straightforward, linear Ruby: call the RPCs you need, parse the returned
  text with plain String/Regexp work, and return a compact summary as the value.

  Guidelines:
  - Always resolve a library id with context7.resolve-library-id before querying
    docs, then use exactly one id per context7.query-docs call.
  - One focused topic per query-docs call; keep tokens at 3000 or less.
  - Rescue SB::ToolError / SB::UnknownTool and retry with adjusted arguments when
    a call fails.
  - Base your final answer strictly on the documentation you fetched; say so when
    the docs do not cover something.
PROMPT

QUESTION = <<~QUESTION
  Use the sandbox to look up the library "RubyLLM" on context7, fetch its
  documentation about defining custom tools, and then answer: how do you define a
  custom tool in RubyLLM? Support the answer with a code example taken strictly
  from the documentation you fetched.
QUESTION

chat = RubyLLM.chat(model: ENV.fetch("MODEL", "deepseek/deepseek-v4-flash-0731"),
                    provider: :openrouter)
      .with_instructions(SYSTEM_PROMPT)
      .with_tools(CodeMode.new)

puts chat.ask(QUESTION).content
