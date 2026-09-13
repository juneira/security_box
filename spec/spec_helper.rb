# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "rspec"
require "timeout"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.pending_failure_output = :no_backtrace
end

# Ensure the image exists before the integration tests
IMAGE_PATH = File.expand_path("../lib/security_box/assets/security_box.wasm", __dir__)

RSpec.configure do |config|
  config.before(:suite) do
    unless File.exist?(IMAGE_PATH)
      puts "Image not found at #{IMAGE_PATH}; building (may take a few minutes)..."
      unless system("bundle exec rake security_box:build_image")
        abort "Failed to build the sandbox image"
      end
    end
  end
end

require "security_box"
