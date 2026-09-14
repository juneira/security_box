# Guest entrypoint packed into the ruby.wasm image (/src/main.rb).
#
# Input: /work/code.rb (preferred) or ARGV[0].
# Result: /work/out.json (JSON envelope); fallback: sentinel line on stdout.
#
# Integrity: the host generates a per-eval random token and passes it via ENV;
# the prelude captures it and scrubs ENV before user code runs. Both the
# envelope and the sentinel line embed the token, and the host rejects any
# result that does not carry the expected token (see lib/security_box/envelope.rb).
# This hardens the channel against forged results (e.g. an at_exit handler
# overwriting out.json); it is defense in depth, not a cryptographic guarantee.
require "json"

require_relative "prelude"

module SB
  SENTINEL = "__SECURITY_BOX_RESULT__"
  WORK_DIR = "/work"

  module_function

  def run
    token = SBPrelude.apply!

    code = fetch_code
    return fatal("no code provided", token) unless code

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = evaluate(code)
    out[:duration_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)
    emit(out, token)
  end

  def fetch_code
    code_path = File.join(WORK_DIR, "code.rb")
    return File.read(code_path) if File.exist?(code_path)

    ARGV[0]
  rescue StandardError, SystemCallError
    ARGV[0]
  end

  def evaluate(code)
    { ok: true, value: jsonable(eval(code, TOPLEVEL_BINDING, "sandbox")) } # rubocop:disable Security/Eval,Style/EvalWithLocation
  rescue Exception => e # rubocop:disable Lint/RescueException
    { ok: false, value: nil, error: { "class" => e.class.name, "message" => e.message.to_s } }
  end

  # Values must survive JSON; the round-trip normalizes what the host will read.
  def jsonable(value)
    JSON.parse(JSON.generate(value))
  rescue StandardError, TypeError
    value.inspect
  end

  # Preferred: /work/out.json. Fallback (no /work): sentinel on stdout.
  # Both carry the sandbox token so the host can reject forged results.
  def emit(out, token)
    json = JSON.generate(out.merge(token: token))
    File.write(File.join(WORK_DIR, "out.json"), json)
  rescue StandardError, SystemCallError
    $stdout.puts "#{SENTINEL}:#{token}:#{json}"
  end

  def fatal(message, token)
    emit({ ok: false, value: nil, error: { "class" => "SecurityBox::Guest", "message" => message } }, token)
  end
end

SB.run
