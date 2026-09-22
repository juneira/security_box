# frozen_string_literal: true

RSpec.describe SecurityBox::Sandbox do
  subject(:sandbox) { described_class.new }

  # Integration suite against the real ruby.wasm: each eval spawns a sandbox.
  # Per-test timeout so a failing kill doesn't hang the suite.
  around do |example|
    Timeout.timeout(30) { example.run }
  end

  describe "#eval" do
    it "runs simple code and returns the value with captured stdout" do
      result = sandbox.eval("puts 'hello'; 40 + 2")

      expect(result).to be_ok
      expect(result.status).to eq(:ok)
      expect(result.value).to eq(42)
      expect(result.stdout).to eq("hello\n")
      expect(result.fuel_used).to be > 0
      expect(result.duration_ms).to be > 0
    end

    it "supports multiple runs on the same object" do
      expect(sandbox.eval("1 + 1").value).to eq(2)
      expect(sandbox.eval("3 * 3").value).to eq(9)
    end

    it "serializes simple objects as the value" do
      expect(sandbox.eval('{ "a" => 1, :b => [true, nil] }').value).to eq({ "a" => 1, "b" => [true, nil] })
    end

    it "serializes non-JSON values as strings" do
      result = sandbox.eval("Object.new")

      expect(result).to be_ok
      expect(result.value).to be_a(String)
    end

    context "when the user code raises an exception" do
      it "returns :error status with class and message" do
        result = sandbox.eval('raise ArgumentError, "boom"')

        expect(result).not_to be_ok
        expect(result.status).to eq(:error)
        expect(result.error["class"]).to eq("ArgumentError")
        expect(result.error["message"]).to eq("boom")
      end

      it "includes a guest-side backtrace with sandbox frames only" do
        result = sandbox.eval("def boom; raise ArgumentError, 'boom'; end\nboom")

        expect(result.error["backtrace"]).to be_an(Array)
        expect(result.error["backtrace"]).to all(be_a(String))
        expect(result.error["backtrace"].first).to include("sandbox:")
        expect(result.error["backtrace"].join("\n")).not_to include("main.rb")
        expect(result.error["backtrace"].join("\n")).not_to include("prelude.rb")
        expect(result.error["backtrace"].join("\n")).not_to include("/home")
      end

      it "caps the backtrace so deep recursion cannot flood the result" do
        result = sandbox.eval("def f; f; end\nf")

        expect(result.status).to eq(:error)
        expect(result.error["backtrace"].size).to be <= 20
      end

      it "captures SystemExit as an error (exit does not kill the host)" do
        result = sandbox.eval("exit 7")

        expect(result.status).to eq(:error)
        expect(result.error["class"]).to eq("SystemExit")
      end
    end

    context "with an infinite loop" do
      it "epoch interruption returns :timeout in ~timeout_ms" do
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = sandbox.eval("while true; end", timeout_ms: 500)
        wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

        expect(result.status).to eq(:timeout)
        expect(wall).to be_between(0.4, 2.0)
      end

      it "does not report fuel_used for :timeout (the epoch trap restores fuel)" do
        result = sandbox.eval("while true; end", timeout_ms: 500)

        expect(result.status).to eq(:timeout)
        expect(result.fuel_used).to be_nil
      end

      it "fuel interruption returns :fuel_exhausted" do
        result = sandbox.eval("while true; end", fuel: 1_000_000)

        expect(result.status).to eq(:fuel_exhausted)
      end
    end

    context "with a memory limit" do
      it "returns :memory_limit when the guest exceeds memory_size" do
        result = sandbox.eval("a = []; loop { a << ('x' * 1024) }", memory_size: 128 * 1024 * 1024, timeout_ms: 15_000)

        expect(result.status).to eq(:memory_limit)
      end

      it "maps a guest NoMemoryError to :memory_limit" do
        # 64MB boots (floor ~36MiB on the stage-6 image) but is too small
        # for a 1MB buffer workload: the Ruby interpreter raises
        # NoMemoryError before the wasm limit is reached.
        result = sandbox.eval(
          'buf = +""; 1024.times { buf << ("x" * 1024) }; buf.bytesize',
          memory_size: 64 * 1024 * 1024, timeout_ms: 15_000
        )

        expect(result.status).to eq(:memory_limit)
      end

      it "returns :sandbox_error (never raises) below the module memory floor" do
        # The stage-6 image (rbwasm build) declares ~576 pages (~36MiB)
        # minimum; below that instantiation fails before the guest boots.
        result = sandbox.eval("1", memory_size: 32 * 1024 * 1024)

        expect(result.status).to eq(:sandbox_error)
        expect(result.value).to be_nil
        expect(result.stderr).to include("security_box:")
        expect(result.stderr).to include("memory")
      end
    end

    context "with output above the limit" do
      it "truncates stdout to the configured limit" do
        result = sandbox.eval('1000.times { print "x" * 1000 }', stdout_limit: 4096)

        expect(result.stdout.bytesize).to be <= 4096
      end
    end
  end
end

RSpec.describe "sandbox isolation" do
  subject(:sandbox) { SecurityBox::Sandbox.new }

  around do |example|
    Timeout.timeout(30) { example.run }
  end

  # NotImplementedError/LoadError inherit from ScriptError, not StandardError —
  # hence the guest needs rescue Exception here.
  def rescued_result(code, **opts)
    sandbox.eval("begin; (#{code}); rescue Exception => ex; \"RESCUED:\#{ex.class}\"; end", **opts)
  end

  it "does not write outside /work" do
    result = rescued_result("File.write('/etc/passwd', 'pwned')")

    expect(result.value).to eq("RESCUED:Errno::ENOENT")
    expect(File.read("/etc/passwd")).not_to include("pwned")
  end

  it "cannot see the host filesystem" do
    result = sandbox.eval('Dir["/*"].empty?')

    expect(result.value).to be(true)
  end

  it "does not execute processes (system raises SecurityError)" do
    result = sandbox.eval("system('touch /tmp/security_box_pwned')")

    expect(result.status).to eq(:error)
    expect(result.error["class"]).to eq("SecurityError")
    expect(File.exist?("/tmp/security_box_pwned")).to be(false)
  end

  it "has no fork" do
    result = rescued_result("fork")

    expect(result.value).to eq("RESCUED:NotImplementedError")
  end

  it "has no sockets" do
    result = rescued_result("require 'socket'")

    expect(result.value).to eq("RESCUED:LoadError")
  end

  it "has no threads" do
    result = rescued_result("Thread.new { 1 }")

    expect(result.value).to eq("RESCUED:NotImplementedError")
  end

  it "has empty ENV" do
    result = sandbox.eval("ENV.to_h")

    expect(result.value).to eq({})
  end
end

RSpec.describe "sandbox hardening prelude" do
  subject(:sandbox) { SecurityBox::Sandbox.new }

  around do |example|
    Timeout.timeout(30) { example.run }
  end

  it "raises SecurityError for backticks" do
    result = sandbox.eval("`ls`")

    expect(result.status).to eq(:error)
    expect(result.error["class"]).to eq("SecurityError")
  end

  it "raises SecurityError for %x" do
    result = sandbox.eval("%x(ls)")

    expect(result.status).to eq(:error)
    expect(result.error["class"]).to eq("SecurityError")
  end

  it "raises SecurityError for IO.popen" do
    result = sandbox.eval("IO.popen('ls')")

    expect(result.status).to eq(:error)
    expect(result.error["class"]).to eq("SecurityError")
  end

  it "raises SecurityError for Process.spawn" do
    result = sandbox.eval("Process.spawn('ls')")

    expect(result.status).to eq(:error)
    expect(result.error["class"]).to eq("SecurityError")
  end

  it "raises SecurityError for Kernel#open (pipe form included)" do
    result = sandbox.eval("open('|ls')")

    expect(result.status).to eq(:error)
    expect(result.error["class"]).to eq("SecurityError")
  end

  it "still allows plain file APIs after neutralizing Kernel#open" do
    result = sandbox.eval("File.write('/work/plain.txt', 'ok'); File.read('/work/plain.txt')")

    expect(result).to be_ok
    expect(result.value).to eq("ok")
  end

  it "does not leak the sandbox token via ENV" do
    result = sandbox.eval("[ENV['SB_TOKEN'], ENV.keys]")

    expect(result).to be_ok
    expect(result.value).to eq([nil, []])
  end
end

RSpec.describe "result channel integrity" do
  subject(:sandbox) { SecurityBox::Sandbox.new }

  around do |example|
    Timeout.timeout(30) { example.run }
  end

  it "rejects an at_exit envelope overwrite without the token" do
    result = sandbox.eval(
      'at_exit { File.write("/work/out.json", %q({"ok":true,"value":"hacked"})) }; 21 * 2'
    )

    expect(result.status).to eq(:sandbox_error)
    expect(result.value).to be_nil
  end

  it "rejects an at_exit overwrite carrying a guessed token" do
    result = sandbox.eval(
      'at_exit { File.write("/work/out.json", ' \
      '%q({"ok":true,"value":"hacked","token":"00000000000000000000000000000000"})) }; 21 * 2'
    )

    expect(result.status).to eq(:sandbox_error)
  end

  it "ignores a forged stdout sentinel when the envelope is valid" do
    result = sandbox.eval(
      'puts "__SECURITY_BOX_RESULT__:deadbeef:{\\"ok\\":true}"; 42'
    )

    expect(result.status).to eq(:ok)
    expect(result.value).to eq(42)
  end

  it "still delivers values from the trusted envelope" do
    result = sandbox.eval('{ "sum" => 21 * 2 }')

    expect(result).to be_ok
    expect(result.value).to eq({ "sum" => 42 })
  end

  it "overwrites stale garbage in out.json with the verified envelope" do
    # User code scribbles on the result channel before returning; the guest's
    # read-back-verified write must win.
    result = sandbox.eval('File.write("/work/out.json", "garbage"); 42')

    expect(result.status).to eq(:ok)
    expect(result.value).to eq(42)
  end
end
