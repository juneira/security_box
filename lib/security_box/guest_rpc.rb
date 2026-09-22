# frozen_string_literal: true

require "json"

module SecurityBox
  # Host side of the guest RPC channel (stage 6).
  #
  # The image statically links the sb_rpc gem, whose C extension declares
  # the wasm import ("sb", "call"). The linker must define it for every
  # instantiation — even when no handlers are configured, or instantiation
  # fails on an unresolved import. Per-eval state (the /work tmpdir, the
  # handler map and the call transcript) travels through Store data and
  # reaches the closure via caller.store_data, so a single definition is
  # safe to share across evaluations, threads and Ractor workers.
  #
  # Protocol (guest side: lib/security_box/guest/rpc.rb):
  #   guest writes /work/rpc_req.json  {"name", "args"}
  #   guest calls SBExt.call           (blocks inside the import)
  #   host executes handlers[name], writes /work/rpc_resp.json
  #   host returns 0 (any non-zero value is a transport failure)
  #
  # Nothing escapes the closure: a raising handler (or any failure in the
  # bridge) becomes an {"ok": false, "error": {"class", "message"}}
  # response the guest can rescue. Messages never include host details
  # (no backtraces, no paths). Handler results are JSON round-tripped,
  # like guest return values — never Marshal.
  module GuestRpc
    IMPORT_MODULE = "sb"
    IMPORT_NAME = "call"
    REQUEST_FILE = "rpc_req.json"
    RESPONSE_FILE = "rpc_resp.json"
    MAX_CALLS = 1_000
    RESULT_LIMIT = 1 << 20

    class << self
      # Defines the import on `linker` (once per linker; state is
      # per-Store). The closure captures nothing — Ractor-safe.
      def define_import(linker)
        linker.func_new(IMPORT_MODULE, IMPORT_NAME, [], [:i32]) do |caller|
          serve(caller)
        end
        nil
      end

      # Per-eval Store data. `handlers` is the configuration's
      # name => callable map, or nil when no rpcs are configured (guest
      # calls still get a clean, rescuable error).
      def store_data(workdir, handlers)
        {
          workdir: workdir,
          rpc: handlers.nil? ? nil : { handlers: handlers, calls: [] }
        }
      end

      private

      def serve(caller)
        data = caller.store_data
        rpc = data[:rpc]
        unless rpc
          return fail_call(data, nil, "SB::UnknownTool",
                           "no RPC handlers are configured for this sandbox")
        end

        request = JSON.parse(File.read(request_path(data)))
        entry = { "name" => request["name"], "args" => request["args"] }
        rpc[:calls] << entry
        dispatch(data, rpc, request, entry)
        0
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Transport/boundary failure (unparsable request, broken /work):
        # encoded as a tool error so the guest gets a rescuable exception
        # instead of the host crashing through the wasm boundary.
        fail_call(data, nil, e.class.name, e.message.to_s)
      end

      def dispatch(data, rpc, request, entry)
        if rpc[:calls].size > MAX_CALLS
          return fail_call(data, entry, "SB::ToolError",
                           "too many RPC calls (limit #{MAX_CALLS})")
        end

        handler = rpc[:handlers][request["name"]]
        if handler.nil?
          return fail_call(data, entry, "SB::UnknownTool",
                           "unknown rpc: #{request["name"]}")
        end

        result = jsonable(handler.call(request["args"]))
        payload = { "ok" => true, "result" => result }
        if JSON.generate(payload).bytesize > RESULT_LIMIT
          return fail_call(data, entry, "SB::ToolError",
                           "rpc result too large (limit #{RESULT_LIMIT} bytes)")
        end

        entry["ok"] = true
        entry["result"] = result
        write_response(data, payload)
      rescue Exception => e # rubocop:disable Lint/RescueException
        fail_call(data, entry, e.class.name, e.message.to_s)
      end

      def fail_call(data, entry, klass, message)
        error = { "class" => klass, "message" => message }
        # The entry (when present) is already in the transcript — mutate
        # it in place instead of pushing a duplicate.
        if entry
          entry["ok"] = false
          entry["error"] = error
        end
        write_response(data, { "ok" => false, "error" => error })
        0
      end

      def request_path(data)
        File.join(data[:workdir], REQUEST_FILE)
      end

      def write_response(data, payload)
        File.write(File.join(data[:workdir], RESPONSE_FILE), JSON.generate(payload))
      end

      # Non-serializable handler results surface as inspect strings, like
      # guest return values (PLAN.md: never Marshal guest/host payloads).
      def jsonable(value)
        JSON.parse(JSON.generate(value))
      rescue StandardError, TypeError
        value.inspect
      end
    end
  end
end
