# frozen_string_literal: true

require "digest"
require "fileutils"
require "wasmtime"

module SecurityBox
  # Content-addressed disk cache for compiled wasm modules.
  #
  # Compiling the ruby.wasm image costs ~15s per process. This cache stores the
  # compiled artifact (Module#serialize) so later processes pay only a fast
  # deserialize. Files live at <cache_dir>/modules/<key>.cwasm, where the key
  # combines the image content digest with the wasmtime precompile compatibility
  # key — a stored module is only reused when the running engine can consume it.
  #
  # Everything here is best effort: on any I/O or deserialization failure the
  # caller falls back to a regular compile and the cache self-heals on the next
  # successful store. Set SECURITY_BOX_CACHE_DIR to relocate the cache; the
  # default is ~/.cache/security_box.
  module ModuleCache
    CACHE_DIR_ENV_VAR = "SECURITY_BOX_CACHE_DIR"

    class << self
      # Returns the cached module for this engine+image, or nil on cache miss,
      # corrupted cache file or any cache error.
      def load_module(engine, image_path)
        path = cache_path(engine, image_path)
        return nil unless path && File.file?(path)

        Wasmtime::Module.deserialize_file(engine, path)
      rescue Wasmtime::Error, TypeError, SystemCallError
        nil
      end

      # Compiles the image and stores the serialized artifact in the cache
      # (best effort). Returns the compiled module in all cases.
      def compile_and_store(engine, image_path)
        module_ = Wasmtime::Module.from_file(engine, image_path)
        store(engine, image_path, module_)
        module_
      end

      def store(engine, image_path, module_)
        path = cache_path(engine, image_path)
        return if path.nil?

        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)
        tmp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.tmp")
        File.binwrite(tmp, module_.serialize)
        File.rename(tmp, path)
      rescue Wasmtime::Error, SystemCallError
        File.delete(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
        nil
      end

      # Nil when no usable cache directory exists (cache disabled).
      def cache_path(engine, image_path)
        dir = modules_dir
        return nil unless dir

        File.join(dir, "#{cache_key(engine, image_path)}.cwasm")
      end

      def modules_dir
        base = ENV[CACHE_DIR_ENV_VAR] || default_base_dir
        return nil unless base

        File.expand_path("modules", base)
      end

      private

      def default_base_dir
        home = ENV["HOME"]
        home && File.join(home, ".cache", "security_box")
      end

      # Digest cost scales with the image size (~0.7s for the 110MB ruby.wasm
      # image); memoized per file identity so it is paid once per process
      # (and recomputed only if the file changes on disk).
      def cache_key(engine, image_path)
        @keys ||= {}
        stat = File.stat(image_path)
        key = @keys[[image_path, stat.size, stat.mtime]]
        return key if key

        image_digest = Digest::SHA256.file(image_path).hexdigest
        @keys[[image_path, stat.size, stat.mtime]] =
          Digest::SHA256.hexdigest("#{image_digest}:#{engine.precompile_compatibility_key}")
      end
    end
  end
end
