# Guest entrypoint packed into the ruby.wasm image (/src/main.rb).
#
# Input: /work/code.rb (preferred) or ARGV[0].
# Result: /work/out.json (JSON envelope); fallback: sentinel line on stdout.
#
# NOTE (stage 1): the result channel is reliable against accidents, not against
# an active adversary (guest code can forge the envelope). Token mitigations and
# schema validation land in Stage 2.
require "json"

module SB
  SENTINEL = "__SECURITY_BOX_RESULT__"
  WORK_DIR = "/work"

  module_function

  def run
    code = fetch_code
    return fatal("no code provided") unless code

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = evaluate(code)
    out[:duration_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(2)
    emit(out)
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
  def emit(out)
    json = JSON.generate(out)
    File.write(File.join(WORK_DIR, "out.json"), json)
  rescue StandardError, SystemCallError
    $stdout.puts "#{SENTINEL}:#{json}"
  end

  def fatal(message)
    emit({ ok: false, value: nil, error: { "class" => "SecurityBox::Guest", "message" => message } })
  end
end

SB.run
