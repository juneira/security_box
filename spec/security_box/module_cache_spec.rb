# frozen_string_literal: true

RSpec.describe SecurityBox::ModuleCache do
  subject(:cache) { described_class }

  # Minimal valid wasm module (magic + version); serialization is engine
  # metadata-heavy but the exact content does not matter for cache semantics.
  let(:wasm_bytes) { [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00].pack("C*") }
  let(:image_path) { File.join(tmpdir, "image.wasm") }
  let(:engine) { Wasmtime::Engine.new }

  around do |example|
    Dir.mktmpdir("security_box_cache_spec") do |dir|
      @tmpdir = dir
      old = ENV[described_class::CACHE_DIR_ENV_VAR]
      ENV[described_class::CACHE_DIR_ENV_VAR] = dir
      example.run
      ENV[described_class::CACHE_DIR_ENV_VAR] = old
    end
  end

  let(:tmpdir) { @tmpdir }

  before do
    File.binwrite(image_path, wasm_bytes)
  end

  describe "#cache_path" do
    it "is stable for the same engine and image" do
      expect(cache.cache_path(engine, image_path)).to eq(cache.cache_path(engine, image_path))
    end

    it "differs for different image contents" do
      other = File.join(tmpdir, "other.wasm")
      File.binwrite(other, wasm_bytes + [0x00].pack("C"))

      expect(cache.cache_path(engine, image_path))
        .not_to eq(cache.cache_path(engine, other))
    end

    it "is disabled when neither the env var nor HOME is available" do
      old_cache_dir = ENV[described_class::CACHE_DIR_ENV_VAR]
      old_home = ENV["HOME"]
      ENV[described_class::CACHE_DIR_ENV_VAR] = nil
      ENV["HOME"] = nil

      expect(cache.modules_dir).to be_nil
      expect(cache.cache_path(engine, image_path)).to be_nil
    ensure
      ENV[described_class::CACHE_DIR_ENV_VAR] = old_cache_dir
      ENV["HOME"] = old_home
    end
  end

  describe "#store + #load_module" do
    it "round-trips a module through the cache" do
      module_ = Wasmtime::Module.from_file(engine, image_path)
      cache.store(engine, image_path, module_)

      expect(File.file?(cache.cache_path(engine, image_path))).to be(true)
      loaded = cache.load_module(engine, image_path)
      expect(loaded).to be_a(Wasmtime::Module)
      expect(loaded.imports).to eq(module_.imports)
    end

    it "returns nil on a cache miss" do
      expect(cache.load_module(engine, image_path)).to be_nil
    end

    it "returns nil and does not raise on a corrupted cache file" do
      module_ = Wasmtime::Module.from_file(engine, image_path)
      cache.store(engine, image_path, module_)
      File.binwrite(cache.cache_path(engine, image_path), "garbage")

      expect(cache.load_module(engine, image_path)).to be_nil
    end

    it "does not raise when the cache directory is unwritable" do
      ENV[described_class::CACHE_DIR_ENV_VAR] = File.join(tmpdir, "blocked")
      Dir.mkdir(File.join(tmpdir, "blocked"))
      File.chmod(0o500, File.join(tmpdir, "blocked"))

      module_ = Wasmtime::Module.from_file(engine, image_path)
      expect { cache.store(engine, image_path, module_) }.not_to raise_error
    ensure
      File.chmod(0o700, File.join(tmpdir, "blocked")) if File.directory?(File.join(tmpdir, "blocked"))
    end

    it "leaves no temporary files behind when storing fails" do
      ENV[described_class::CACHE_DIR_ENV_VAR] = File.join(tmpdir, "blocked2")
      Dir.mkdir(File.join(tmpdir, "blocked2"))
      File.chmod(0o500, File.join(tmpdir, "blocked2"))

      module_ = Wasmtime::Module.from_file(engine, image_path)
      cache.store(engine, image_path, module_)

      expect(Dir.children(File.join(tmpdir, "blocked2"))).to be_empty
    ensure
      File.chmod(0o700, File.join(tmpdir, "blocked2")) if File.directory?(File.join(tmpdir, "blocked2"))
    end
  end

  describe "#compile_and_store" do
    it "compiles, persists and reloads without compiling" do
      module_ = cache.compile_and_store(engine, image_path)

      expect(module_).to be_a(Wasmtime::Module)
      expect(File.file?(cache.cache_path(engine, image_path))).to be(true)
      expect(cache.load_module(engine, image_path)).to be_a(Wasmtime::Module)
    end
  end
end
