# frozen_string_literal: true

# RSpec inside the security_box sandbox.
#
# The sandbox image bundles RSpec. This sample keeps a small library and its
# spec under ruby_src/, mounts that folder read-only at /ruby_src and runs the
# existing suite with the sandbox's /work directory as cwd:
#
#   host -> sandbox.eval -> SB.run_rspec(/ruby_src/spec, chdir: /work)
#              -> RSpec::Core::Runner, returns the exit status
#
# Usage:
#   cd samples/rspec_sandbox
#   bundle install
#   bundle exec ruby run.rb

require "security_box"

RUBY_SRC = File.expand_path("ruby_src", __dir__)

SecurityBox.register(:rspec) do |c|
  # Read-only: guest code can read the sources but cannot modify the checkout.
  c.mount RUBY_SRC => "/ruby_src"
  # RSpec boots Ruby and loads the framework; give the suite room to run.
  c.timeout_ms 30_000
  c.fuel_ms 20_000
end

box = SecurityBox.spawn(:rspec)

def run_guest(box, title, code)
  puts "== #{title}"
  result = box.eval(code)
  puts "status:   #{result.status}"
  puts "value:    #{result.value.inspect}"
  puts "duration: #{result.duration_ms.round}ms"
  puts "stdout:"
  puts result.stdout
  unless result.stderr.to_s.empty?
    puts "stderr:"
    puts result.stderr
  end
  puts "error:    #{result.error.inspect}" if result.error
  puts
  result
end

passed = run_guest(box, "ruby_src suite (cwd /work)", <<~RUBY)
  SB.run_rspec("--no-color", "-I", "/ruby_src", "/ruby_src/spec", chdir: "/work")
RUBY

if passed.value == 0
  puts "the ruby_src suite passed (RSpec status 0)"
else
  puts "RSpec status #{passed.value}: the suite has failures; see the RSpec output above."
end