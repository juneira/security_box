# Hardening prelude — loaded before user code (defense in depth; WASI is the
# primary isolation boundary).
#
# Responsibilities (in order):
#   1. capture the per-eval sandbox token from ENV and hand it to the guest
#      protocol exactly once (main.rb), erasing every other reference;
#   2. scrub ENV so user code sees an empty environment;
#   3. neutralize the process-spawn APIs that WASI leaves as misleading stubs
#      (e.g. `system` returns true without running anything) by raising
#      SecurityError instead;
#   4. disable Kernel#open entirely (its pipe form executes processes; user
#      code must use File.open/IO.read for plain files);
#   5. set $stdout.sync so captured output is not lost on a hard kill.
module SBPrelude
  DENIED_MESSAGE = "process execution is not allowed inside the sandbox"

  class << self
    # Applies all hardening and returns the sandbox token (or nil). The token
    # is removed from the prelude state; afterwards it exists only in the
    # caller's local scope.
    def apply!
      capture_token
      scrub_env
      neutralize_process_apis
      sync_stdout
      take_token
    end

    # Returns the token captured by apply! and erases the stored reference.
    def take_token
      token = @token
      remove_instance_variable(:@token) if instance_variable_defined?(:@token)
      token
    end

    private

    def capture_token
      @token = ENV["SB_TOKEN"]
    end

    def scrub_env
      ENV.each_key { |key| ENV.delete(key) }
    end

    def neutralize_process_apis
      %w[system exec spawn `].each do |name|
        neutralize_instance_method(Kernel, name)
      end
      neutralize_instance_method(Kernel, "open")
      neutralize_singleton_method(IO, :popen)
      neutralize_singleton_method(Process, :spawn)
    end

    def neutralize_instance_method(owner, name)
      owner.module_eval do
        define_method(name) { |*args, **kwargs| raise SecurityError, DENIED_MESSAGE }
      end
    end

    def neutralize_singleton_method(owner, name)
      owner.define_singleton_method(name) do |*args, **kwargs|
        raise SecurityError, DENIED_MESSAGE
      end
    end

    def sync_stdout
      $stdout.sync = true
    end
  end
end
