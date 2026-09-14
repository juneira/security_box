# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

# ruby.wasm release used to build the guest image, pinned for reproducibility.
# Bump this (and remove ruby-4.0-wasm32-unknown-wasip1-full*) to pick up a new
# ruby.wasm release.
RUBY_WASM_TAG = "2.10.1"
TARBALL = "ruby-4.0-wasm32-unknown-wasip1-full.tar.gz"
TOOLCHAIN_DIR = TARBALL.delete_suffix(".tar.gz")
IMAGE_PATH = "lib/security_box/assets/security_box.wasm"
GUEST_DIR = "lib/security_box/guest"

namespace :security_box do
  desc "Download and pack the ruby.wasm image with the guest script (output: #{IMAGE_PATH})"
  task :build_image do
    mkdir_p File.dirname(IMAGE_PATH)

    if image_fresh?
      puts "Sandbox image is up to date (ruby.wasm #{RUBY_WASM_TAG}); skipping repack."
      next
    end

    unless File.exist?(File.join(TOOLCHAIN_DIR, "usr/local/bin/ruby"))
      sh "curl -sLO https://github.com/ruby/ruby.wasm/releases/download/#{RUBY_WASM_TAG}/#{TARBALL}"
      sh "tar xfz #{TARBALL}"
    end
    sh "bundle exec rbwasm pack #{TOOLCHAIN_DIR}/usr/local/bin/ruby " \
       "--dir ./#{TOOLCHAIN_DIR}/usr::/usr " \
       "--dir ./#{GUEST_DIR}::/src -o #{IMAGE_PATH}"
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
  Dir["#{GUEST_DIR}/*.rb"]
end