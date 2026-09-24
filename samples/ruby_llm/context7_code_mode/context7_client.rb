# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# Minimal MCP (Model Context Protocol) client for a streamable-HTTP server,
# written with the Ruby standard library only. It speaks to the hosted
# Context7 endpoint (https://mcp.context7.com/mcp), authenticating with a
# bearer API key.
#
# The client runs on the host only: guest code inside the sandbox has no
# network access and no access to the API key. The security_box RPC
# handlers registered in sandbox_profile.rb call into this client, and
# their results travel back into the guest through the SB.call channel as
# plain JSON — the key never crosses the sandbox boundary.
class Context7Client
  DEFAULT_URL = "https://mcp.context7.com/mcp"
  PROTOCOL_VERSION = "2025-03-26"
  CLIENT_INFO = { name: "security_box_context7_code_mode", version: "1.0.0" }.freeze
  OPEN_TIMEOUT = 10      # seconds to establish the TCP/TLS connection
  READ_TIMEOUT = 60      # seconds per request; query-docs can be slow

  # Raised for any transport/protocol/tool failure. When raised inside a
  # security_box RPC handler, the guest sees a rescuable SB::ToolError
  # carrying class + message only (no host details).
  Error = Class.new(StandardError)

  def initialize(api_key:, url: DEFAULT_URL)
    raise Error, "CONTEXT7_API_KEY is not set" if api_key.to_s.strip.empty?

    @api_key = api_key
    @url = url
    @session_id = nil
    @server_info = nil
    @next_id = 0
    @mutex = Mutex.new
  end

  # MCP handshake: initialize + initialized notification. Returns the
  # server's initialize result (serverInfo, capabilities, instructions).
  def initialize!
    @server_info = request("initialize",
                           protocolVersion: PROTOCOL_VERSION,
                           capabilities: {},
                           clientInfo: CLIENT_INFO)
    notify("notifications/initialized")
    @server_info
  end

  def server_info
    @server_info
  end

  # Array of tool descriptors (name, description, inputSchema, ...).
  def list_tools
    request("tools/list")["tools"]
  end

  # Executes a tool and returns the text content of its response as a
  # String. Raises Context7Client::Error when the tool reports isError or
  # the server returns a JSON-RPC error.
  def call_tool!(name, arguments = {})
    result = request("tools/call", name: name, arguments: arguments)
    text = Array(result && result["content"])
           .select { |block| block["type"] == "text" }
           .map { |block| block["text"] }
           .join("\n")
    raise Error, text.empty? ? "tool #{name} failed" : text if result["isError"]
    raise Error, "tool #{name} returned no text content" if text.empty?

    text
  end

  private

  def request(method, params = {})
    id = nil
    payload = nil
    @mutex.synchronize do
      id = @next_id += 1
      payload = { jsonrpc: "2.0", id: id, method: method, params: params }
    end
    message = post(payload)
    raise Error, jsonrpc_error(message) if message["error"]

    message["result"]
  end

  # Fire-and-forget notification (no id, no response expected).
  def notify(method)
    post({ jsonrpc: "2.0", method: method })
  rescue Error
    nil
  end

  # Sends one JSON-RPC message and returns the matching response message.
  # Responses arrive as SSE (event: message / data: {...}) or, per the
  # spec, possibly as plain JSON — both are handled.
  def post(payload)
    @mutex.synchronize do
      response = http.post(uri.request_uri, JSON.generate(payload), headers)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "context7 HTTP #{response.code}: #{response.body.to_s[0, 300]}"
      end

      @session_id = response["Mcp-Session-Id"] if response["Mcp-Session-Id"]
      parse_response(response.body, payload[:id])
    end
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
    raise Error, "context7 transport failure: #{e.class}: #{e.message}"
  end

  def http
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http
  end

  def headers
    base = {
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }
    base["Authorization"] = "Bearer #{@api_key}"
    base["Mcp-Session-Id"] = @session_id if @session_id
    base
  end

  def parse_response(body, request_id)
    JSON.parse(sse_message(body, request_id) || body)
  rescue JSON::ParserError => e
    raise Error, "unparsable MCP response: #{e.message}"
  end

  # Returns the first SSE data line carrying a JSON-RPC response for this
  # request (interleaved pings/notifications are skipped).
  def sse_message(body, request_id)
    return nil unless body&.include?("data:")

    fallback = nil
    body.each_line do |line|
      next unless line.start_with?("data:")

      raw = line.sub(/\Adata:\s?/, "").strip
      message = begin
        JSON.parse(raw)
      rescue JSON::ParserError
        next
      end
      next unless message.is_a?(Hash) && (message.key?("result") || message.key?("error"))
      return raw if message["id"] == request_id

      fallback ||= raw
    end
    fallback
  end

  def jsonrpc_error(message)
    error = message["error"] || {}
    "MCP error #{error["code"]}: #{error["message"]}"
  end

  def uri
    @uri ||= URI.parse(@url)
  end
end
