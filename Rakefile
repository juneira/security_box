# frozen_string_literal: true

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

namespace :security_box do
  desc "Download and pack the ruby.wasm image with the guest script"
  task :build_image do
    sh "mkdir -p build"
    unless File.exist?("ruby-4.0-wasm32-unknown-wasip1-full/usr/local/bin/ruby")
      sh "curl -sLO https://github.com/ruby/ruby.wasm/releases/latest/download/ruby-4.0-wasm32-unknown-wasip1-full.tar.gz"
      sh "tar xfz ruby-4.0-wasm32-unknown-wasip1-full.tar.gz"
    end
    sh "bundle exec rbwasm pack ruby-4.0-wasm32-unknown-wasip1-full/usr/local/bin/ruby " \
       "--dir ./ruby-4.0-wasm32-unknown-wasip1-full/usr::/usr " \
       "--dir ./lib/security_box/guest::/src -o build/security_box.wasm"
  end
end

task default: :spec
