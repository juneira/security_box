# frozen_string_literal: true

RSpec.describe SecurityBox::Envelope do
  subject(:envelope) { described_class }

  let(:token) { "a" * 32 }

  def valid_ok_envelope
    { "ok" => true, "value" => 42, "token" => token, "duration_ms" => 1.5 }
  end

  def valid_error_envelope
    { "ok" => false, "value" => nil,
      "error" => { "class" => "ArgumentError", "message" => "boom" },
      "token" => token, "duration_ms" => 2.0 }
  end

  describe ".parse" do
    it "accepts a valid ok envelope" do
      expect(envelope.parse(JSON.generate(valid_ok_envelope), token))
        .to eq(valid_ok_envelope)
    end

    it "accepts a valid error envelope" do
      expect(envelope.parse(JSON.generate(valid_error_envelope), token))
        .to eq(valid_error_envelope)
    end

    it "accepts value: null on ok envelopes (explicit key)" do
      raw = JSON.generate({ "ok" => true, "value" => nil, "token" => token })

      expect(envelope.parse(raw, token)).to include("ok" => true, "value" => nil)
    end

    it "rejects a token mismatch" do
      raw = JSON.generate(valid_ok_envelope.merge("token" => "f" * 32))

      expect(envelope.parse(raw, token)).to be_nil
    end

    it "rejects a missing token" do
      raw = JSON.generate(valid_ok_envelope.except("token"))

      expect(envelope.parse(raw, token)).to be_nil
    end

    it "rejects a nil/empty expected token (host must always generate one)" do
      raw = JSON.generate(valid_ok_envelope)

      expect(envelope.parse(raw, nil)).to be_nil
      expect(envelope.parse(raw, "")).to be_nil
    end

    it "rejects non-boolean ok" do
      raw = JSON.generate(valid_ok_envelope.merge("ok" => "true"))

      expect(envelope.parse(raw, token)).to be_nil
    end

    it "rejects ok:true without a value key" do
      raw = JSON.generate({ "ok" => true, "token" => token })

      expect(envelope.parse(raw, token)).to be_nil
    end

    it "rejects ok:false without an error hash" do
      raw = JSON.generate({ "ok" => false, "token" => token })

      expect(envelope.parse(raw, token)).to be_nil
    end

    it "rejects ok:false with malformed error fields" do
      raw = JSON.generate({ "ok" => false, "token" => token,
                            "error" => { "class" => 1, "message" => "boom" } })

      expect(envelope.parse(raw, token)).to be_nil
    end

    it "accepts ok:false with a valid backtrace array" do
      raw = JSON.generate(valid_error_envelope.merge(
        "error" => { "class" => "ArgumentError", "message" => "boom",
                     "backtrace" => ["sandbox:1:in 'Object#boom'", "sandbox:1:in '<main>'"] }
      ))

      expect(envelope.parse(raw, token)).not_to be_nil
    end

    it "accepts ok:false without a backtrace (backwards compatibility)" do
      expect(envelope.parse(JSON.generate(valid_error_envelope), token)).not_to be_nil
    end

    it "rejects ok:false with a backtrace containing non-strings" do
      raw = JSON.generate(valid_error_envelope.merge(
        "error" => { "class" => "ArgumentError", "message" => "boom",
                     "backtrace" => ["sandbox:1", 42] }
      ))

      expect(envelope.parse(raw, token)).to be_nil
    end

    it "rejects ok:false with a non-array backtrace" do
      raw = JSON.generate(valid_error_envelope.merge(
        "error" => { "class" => "ArgumentError", "message" => "boom",
                     "backtrace" => "sandbox:1:in 'Object#boom'" }
      ))

      expect(envelope.parse(raw, token)).to be_nil
    end

    it "rejects a non-numeric duration_ms" do
      raw = JSON.generate(valid_ok_envelope.merge("duration_ms" => "soon"))

      expect(envelope.parse(raw, token)).to be_nil
    end

    it "rejects non-Hash JSON documents" do
      expect(envelope.parse(JSON.generate([1, 2]), token)).to be_nil
      expect(envelope.parse(JSON.generate("ok"), token)).to be_nil
      expect(envelope.parse(JSON.generate(42), token)).to be_nil
    end

    it "rejects corrupt JSON" do
      expect(envelope.parse("{not json", token)).to be_nil
    end

    it "rejects nil input" do
      expect(envelope.parse(nil, token)).to be_nil
    end
  end

  describe ".from_stdout" do
    def sentinel_line(json)
      "#{described_class::SENTINEL}:#{token}:#{json}"
    end

    it "extracts a single valid sentinel line" do
      stdout = "guest says hi\n#{sentinel_line(JSON.generate(valid_ok_envelope))}\n"

      expect(envelope.from_stdout(stdout, token)).to eq(valid_ok_envelope)
    end

    it "returns nil when no sentinel line is present" do
      expect(envelope.from_stdout("regular output\n", token)).to be_nil
      expect(envelope.from_stdout("", token)).to be_nil
    end

    it "returns nil on multiple sentinel lines (count check)" do
      json = JSON.generate(valid_ok_envelope)
      stdout = "#{sentinel_line(json)}\n#{sentinel_line(json)}\n"

      expect(envelope.from_stdout(stdout, token)).to be_nil
    end

    it "returns nil when the sentinel carries a wrong token" do
      forged = valid_ok_envelope.merge("token" => "f" * 32)
      stdout = "#{sentinel_line(JSON.generate(forged))}\n"

      expect(envelope.from_stdout(stdout, token)).to be_nil
    end

    it "returns nil when the sentinel payload is corrupt" do
      stdout = "#{sentinel_line("{nope")}\n"

      expect(envelope.from_stdout(stdout, token)).to be_nil
    end

    it "keeps JSON payloads containing colons intact" do
      envelope_with_colons = valid_ok_envelope.merge("value" => "a:b:c")
      stdout = "#{sentinel_line(JSON.generate(envelope_with_colons))}\n"

      expect(envelope.from_stdout(stdout, token)).to eq(envelope_with_colons)
    end
  end
end
