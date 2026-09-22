# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# Stage 6 (host RPC): the image is no longer packed from a prebuilt ruby.wasm
# release tarball. It is built from the pinned Ruby source with the guest
# gems of lib/security_box/guest_ext (sb_rpc — the C extension that declares
# the "sb"/"call" wasm import) statically linked, via `rbwasm build`. The
# guest entrypoint dir is then added to the VFS with `rbwasm pack`.
#
# First build downloads the Ruby source tarball, wasi-sdk and binaryen into
# build/ (network required); subsequent builds reuse the cached artifacts.
RUBY_WASM_BUILD_VERSION = "4.0" # rbwasm build alias (see ruby_wasm CLI)
GUEST_DIR = "lib/security_box/guest"
GUEST_EXT_DIR = "lib/security_box/guest_ext"
BASE_IMAGE_PATH = "build/security_box_base.wasm"
IMAGE_PATH = "lib/security_box/assets/security_box.wasm"

namespace :security_box do
  desc "Build the sandbox image with guest gems statically linked (output: #{IMAGE_PATH})"
  task :build_image do
    mkdir_p File.dirname(IMAGE_PATH)

    if image_fresh?
      puts "Sandbox image is up to date; skipping rebuild."
      next
    end

    lockfile = File.join(GUEST_EXT_DIR, "Gemfile.lock")
    base_image = File.expand_path(BASE_IMAGE_PATH)
    build_command =
      "bundle exec rbwasm build --ruby-version #{RUBY_WASM_BUILD_VERSION} " \
      "--target wasm32-unknown-wasip1 --build-profile full " \
      "-o #{base_image}"

    # The build runs under the guest_ext bundle (sb_rpc + ruby_wasm), from
    # its own directory, with the parent's bundler injection stripped — a
    # leaked BUNDLE_GEMFILE/RUBYOPT can rewrite the wrong lockfile.
    Bundler.with_unbundled_env do
      ENV["RUBY_WASM_ROOT"] = Dir.pwd
      sh("bundle lock") unless File.exist?(lockfile)
      Dir.chdir(GUEST_EXT_DIR) do
        sh(build_command)
      end
      ENV.delete("RUBY_WASM_ROOT")
    end
    sh("bundle exec rbwasm pack #{base_image} " \
       "--dir #{GUEST_DIR}::/src -o #{IMAGE_PATH}")
  end

  desc "Fail if the sandbox image is missing or older than the guest sources"
  task :verify_image do
    unless File.exist?(IMAGE_PATH)
      abort "Sandbox image missing at #{IMAGE_PATH}; run `rake security_box:build_image`"
    end
    stale = guest_files.select { |f| File.mtime(IMAGE_PATH) < File.mtime(f) }
    unless stale.empty?
      abort "Sandbox image is stale (guest sources changed: #{stale.join(', ')}); " \
            "run `rake security_box:build_image`"
    end
  end
end

# The gem ships the packed image, so make sure it exists and is fresh before
# packaging (`rake build`/`rake release`).
task build: "security_box:build_image"

# Hard guard for releases: never publish a gem with a missing or stale image.
# (`release` already depends on build -> build_image; this fails fast and
# explicitly if the image is ever out of sync with the guest sources.)
task release: "security_box:verify_image"

task default: :spec

def image_fresh?
  return false unless File.exist?(IMAGE_PATH)

  mtime = File.mtime(IMAGE_PATH)
  guest_files.all? { |f| mtime >= File.mtime(f) } &&
    mtime >= File.mtime(__FILE__)
end

def guest_files
  Dir["#{GUEST_DIR}/*.rb"] + Dir["#{GUEST_EXT_DIR}/**/*.{rb,c,gemspec}"] +
    [File.join(GUEST_EXT_DIR, "Gemfile")]
end
