# frozen_string_literal: true

RSpec.describe SecurityBox::Mounts do
  describe ".normalize" do
    def normalize(mounts)
      described_class.normalize(mounts)
    end

    it "returns an empty frozen array for nil" do
      expect(normalize(nil)).to eq([])
      expect(normalize(nil)).to be_frozen
    end

    it "freezes the array and each entry" do
      mounts = normalize([{ host: "/tmp", guest: "/data", mode: :read_only }])

      expect(mounts).to be_frozen
      expect(mounts.first).to be_frozen
      expect(mounts.first.keys).to eq(%i[host guest mode])
    end

    it "expands relative host paths against Dir.pwd" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          mounts = normalize([{ host: "data", guest: "/data", mode: :read_only }])

          expect(mounts.first[:host]).to eq(File.expand_path("data"))
        end
      end
    end

    it "normalizes a trailing slash on the guest path" do
      mounts = normalize([{ host: "/tmp", guest: "/data/", mode: :read_only }])

      expect(mounts.first[:guest]).to eq("/data")
    end

    it "rejects an unknown mode (wasmtime silently accepts bogus symbols)" do
      expect { normalize([{ host: "/tmp", guest: "/data", mode: :bogus }]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /mode must be one of/)
    end

    it "rejects non-hash entries" do
      expect { normalize(["/tmp"]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /must be a Hash with exactly/)
    end

    it "rejects entries with missing or extra keys" do
      expect { normalize([{ host: "/tmp", guest: "/data" }]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /exactly :host, :guest and :mode/)
      expect { normalize([{ host: "/tmp", guest: "/data", mode: :read_only, extra: 1 }]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /exactly :host, :guest and :mode/)
    end

    it "rejects an empty or non-string host path" do
      expect { normalize([{ host: "", guest: "/data", mode: :read_only }]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /host path must be a non-empty String/)
      expect { normalize([{ host: nil, guest: "/data", mode: :read_only }]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /host path must be a non-empty String/)
    end

    it "rejects a relative guest path" do
      expect { normalize([{ host: "/tmp", guest: "data", mode: :read_only }]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /guest path must be absolute/)
    end

    it "rejects the guest root and unnormalized guest paths" do
      expect { normalize([{ host: "/tmp", guest: "/", mode: :read_only }]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /normalized absolute path/)
      expect { normalize([{ host: "/tmp", guest: "/data/../etc", mode: :read_only }]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /normalized absolute path/)
    end

    it "rejects overlaps with reserved guest paths (exact or nested)" do
      %w[/work /usr /src /work/sub /usr/local /src/lib].each do |guest|
        expect { normalize([{ host: "/tmp", guest: guest, mode: :read_only }]) }
          .to raise_error(SecurityBox::InvalidConfiguration, /overlaps the reserved path/)
      end
    end

    it "rejects duplicate guest paths" do
      mounts = [{ host: "/tmp/a", guest: "/data", mode: :read_only },
                { host: "/tmp/b", guest: "/data", mode: :read_only }]

      expect { normalize(mounts) }
        .to raise_error(SecurityBox::InvalidConfiguration, %r{duplicate guest mount path "/data"})
    end

    it "rejects more than MAX_MOUNTS mounts" do
      mounts = Array.new(described_class::MAX_MOUNTS + 1) do |i|
        { host: "/tmp/dir#{i}", guest: "/d#{i}", mode: :read_only }
      end

      expect { normalize(mounts) }.to raise_error(SecurityBox::InvalidConfiguration, /too many mounts/)
      expect(normalize(mounts.first(described_class::MAX_MOUNTS)).size).to eq(described_class::MAX_MOUNTS)
    end
  end
end

RSpec.describe "mount configuration DSL" do
  # The Builder DSL is exposed through Registry.register; for unit tests we
  # drive a Builder directly and hand its changes to Configuration.build.
  def build_with_mounts
    builder = SecurityBox::Configuration::Builder.new
    yield builder
    SecurityBox::Configuration.build(**builder.changes)
  end

  it "mounts read-only by default and accumulates across calls" do
    config = build_with_mounts do |c|
      c.mount "/tmp/a" => "/a"
      c.mount_rw "/tmp/b" => "/b"
      c.mount "/tmp/c" => "/c"
    end

    expect(config.mounts.map { |m| [m[:guest], m[:mode]] }).to eq([
      ["/a", :read_only], ["/b", :read_write], ["/c", :read_only]
    ])
  end

  it "expands relative host paths at DSL time" do
    config = build_with_mounts { |c| c.mount "lib" => "/lib" }

    expect(config.mounts.first[:host]).to eq(File.expand_path("lib"))
  end

  it "rejects mappings that are not exactly one pair" do
    expect {
      build_with_mounts { |c| c.mount("/tmp/a" => "/a", "/tmp/b" => "/b") }
    }.to raise_error(SecurityBox::InvalidConfiguration, /exactly one pair/)
    expect {
      build_with_mounts { |c| c.mount("/tmp/a") }
    }.to raise_error(SecurityBox::InvalidConfiguration, /exactly one pair/)
  end

  describe "#with" do
    it "replaces mounts without mutating the receiver" do
      base = SecurityBox::Configuration.build(mounts: [{ host: "/tmp/a", guest: "/a", mode: :read_only }])
      derived = base.with(mounts: [{ host: "/tmp/b", guest: "/b", mode: :read_write }])

      expect(derived.mounts).to eq([{ host: "/tmp/b", guest: "/b", mode: :read_write }])
      expect(base.mounts).to eq([{ host: "/tmp/a", guest: "/a", mode: :read_only }])
    end

    it "keeps the mounts when deriving other options" do
      base = SecurityBox::Configuration.build(mounts: [{ host: "/tmp/a", guest: "/a", mode: :read_only }])

      expect(base.with(timeout_ms: 100).mounts).to eq(base.mounts)
    end

    it "rejects invalid derived mounts" do
      base = SecurityBox::Configuration.build

      expect { base.with(mounts: [{ host: "/tmp", guest: "/work", mode: :read_only }]) }
        .to raise_error(SecurityBox::InvalidConfiguration, /reserved path/)
    end
  end

  describe "#fingerprint" do
    it "changes when the mounts change" do
      base = SecurityBox::Configuration.build

      expect(base.with(mounts: [{ host: "/tmp/a", guest: "/a", mode: :read_only }]).fingerprint)
        .not_to eq(base.fingerprint)
    end

    it "is equal for equal mounts regardless of how they were built" do
      via_dsl = build_with_mounts { |c| c.mount_rw "/tmp/a" => "/a" }
      via_hash = SecurityBox::Configuration.build(mounts: [{ host: "/tmp/a", guest: "/a", mode: :read_write }])

      expect(via_dsl.fingerprint).to eq(via_hash.fingerprint)
    end
  end
end

RSpec.describe "sandbox folder mounts" do
  subject(:sandbox) { SecurityBox::Sandbox.new }

  around do |example|
    Timeout.timeout(30) { example.run }
  end

  let(:data_dir) do
    dir = Dir.mktmpdir("sb-mount")
    File.write(File.join(dir, "hello.txt"), "hello from host\n")
    FileUtils.mkdir_p(File.join(dir, "sub"))
    File.write(File.join(dir, "sub", "nested.txt"), "nested\n")
    dir
  end

  after do
    FileUtils.remove_entry(data_dir) if File.directory?(data_dir)
  end

  def ro_mount
    { host: data_dir, guest: "/data", mode: :read_only }
  end

  it "reads host files through a read-only mount" do
    result = sandbox.eval('File.read("/data/hello.txt")', mounts: [ro_mount])

    expect(result).to be_ok
    expect(result.value).to eq("hello from host\n")
  end

  it "lists and opens mounted content (Dir[], File.open, nested dirs)" do
    result = sandbox.eval(<<~'RUBY', mounts: [ro_mount])
      {
        glob: Dir["/data/**/*"].sort,
        open: File.open("/data/hello.txt", "r") { |f| f.read(5) },
        nested: File.read("/data/sub/nested.txt")
      }
    RUBY

    expect(result).to be_ok
    expect(result.value["glob"]).to include("/data/hello.txt", "/data/sub", "/data/sub/nested.txt")
    expect(result.value["open"]).to eq("hello")
    expect(result.value["nested"]).to eq("nested\n")
  end

  it "fails write attempts into a read-only mount (Errno::EPERM) and leaves the host dir unchanged" do
    listing_before = Dir.children(data_dir).sort
    result = sandbox.eval(<<~'RUBY', mounts: [{ host: data_dir, guest: "/data", mode: :read_only }])
      begin
        File.write("/data/evil.txt", "x")
        "WROTE(!)"
      rescue Exception => ex
        "RESCUED #{ex.class}"
      end
    RUBY

    expect(result).to be_ok
    expect(result.value).to eq("RESCUED Errno::EPERM")
    expect(Dir.children(data_dir).sort).to eq(listing_before)
  end

  it "round-trips writes through a read-write mount (host sees guest files)" do
    result = sandbox.eval(
      'File.write("/rw/made_by_guest.txt", "guest was here")',
      mounts: [{ host: data_dir, guest: "/rw", mode: :read_write }]
    )

    expect(result).to be_ok
    expect(File.read(File.join(data_dir, "made_by_guest.txt"))).to eq("guest was here")
  end

  it "coexists with /work, stdlib and several mounts at once" do
    dir2 = Dir.mktmpdir("sb-mount2")
    File.write(File.join(dir2, "two.txt"), "2")
    begin
      result = sandbox.eval(<<~'RUBY', mounts: [ro_mount, { host: dir2, guest: "/two", mode: :read_only }])
        {
          stdlib: JSON.generate({ "a" => 1 }),
          work: File.write("/work/x.txt", "1"),
          data: File.read("/data/hello.txt"),
          two: File.read("/two/two.txt")
        }
      RUBY

      expect(result).to be_ok
      expect(result.value["stdlib"]).to eq('{"a":1}')
      expect(result.value["work"]).to eq(1)
      expect(result.value["data"]).to eq("hello from host\n")
      expect(result.value["two"]).to eq("2")
    ensure
      FileUtils.remove_entry(dir2) if File.directory?(dir2)
    end
  end

  it "maps a vanished host directory to :sandbox_error with a security_box note" do
    result = sandbox.eval("1", mounts: [{ host: "/nonexistent_#{Process.pid}_sb", guest: "/data", mode: :read_only }])

    expect(result.status).to eq(:sandbox_error)
    expect(result.value).to be_nil
    expect(result.stderr).to include("security_box:")
    expect(result.stderr).to include("does not exist or is not a directory")
  end

  it "uses profile-level mounts via register/spawn" do
    SecurityBox::Registry.clear!
    begin
      SecurityBox.register(:mount_spec_profile) do |c|
        c.mount data_dir => "/data"
      end
      box = SecurityBox.spawn(:mount_spec_profile)

      expect(box.eval('File.read("/data/hello.txt")').value).to eq("hello from host\n")
      expect(box.eval('File.read("/data/hello.txt")').value).to eq("hello from host\n")
    ensure
      SecurityBox::Registry.clear!
    end
  end
end

RSpec.describe "RactorPool folder mounts" do
  around do |example|
    Timeout.timeout(60) { example.run }
  end

  it "evals with mounts on a worker Ractor" do
    dir = Dir.mktmpdir("sb-mount")
    File.write(File.join(dir, "hello.txt"), "from ractor\n")
    pool = SecurityBox.ractor_pool(
      SecurityBox::Configuration.build(mounts: [{ host: dir, guest: "/data", mode: :read_only }]),
      size: 1
    )
    begin
      result = pool.eval('File.read("/data/hello.txt")')

      expect(result).to be_ok
      expect(result.value).to eq("from ractor\n")
    ensure
      pool.shutdown
      FileUtils.remove_entry(dir) if File.directory?(dir)
    end
  end
end
