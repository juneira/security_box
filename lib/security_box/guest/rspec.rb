# Guest-side RSpec runner (loaded by main.rb before user code).
#
# The image bundles RSpec (see lib/security_box/guest_ext/Gemfile), so guest
# code can run a spec suite written to /work or mounted at another path:
#
#   SB.run_rspec("--no-color", "/work/spec")
#   SB.run_rspec("-I", "/project/lib", "/project/spec", chdir: "/project")
#
# RSpec is required lazily on the first call, so ordinary evals do not pay
# the load cost. The runner returns RSpec's exit status (0 = all examples
# passed) instead of exiting the process, keeping the envelope channel intact.
module SB
  module_function

  # Runs RSpec with `args` (an argv-style list) and returns its exit status.
  # The suite runs with cwd and HOME set to `chdir` (default /work) so
  # relative paths, `.rspec` discovery and RSpec's status/cache files stay
  # inside a writable directory.
  def run_rspec(*args, chdir: "/work")
    previous_home = ENV["HOME"]
    previous_pwd = Dir.pwd
    load_rspec!

    work = if File.directory?(chdir)
             chdir
           elsif File.directory?("/work")
             "/work"
           else
             previous_pwd
           end
    ENV["HOME"] = work
    Dir.chdir(work)

    RSpec::Core::Runner.run(args.flatten, $stderr, $stdout)
  ensure
    Dir.chdir(previous_pwd) if previous_pwd && File.directory?(previous_pwd)
    if previous_home.nil?
      ENV.delete("HOME")
    else
      ENV["HOME"] = previous_home
    end
  end

  def load_rspec!
    require "/bundle/setup.rb"
    require "rspec/core"
    # Hide the embedded guest protocol frames (/src/main.rb, /src/rspec.rb,
    # ...) from RSpec's printed failure backtraces; the sandbox reserves /src,
    # so this cannot hide user files.
    RSpec.configure do |config|
      config.backtrace_exclusion_patterns << %r{\A/src/}
    end
  rescue LoadError => e
    raise LoadError,
          "rspec is not available in this image (#{e.message}); " \
          "rebuild it with `bundle exec rake security_box:build_image`"
  end
  private_class_method :load_rspec!
end
