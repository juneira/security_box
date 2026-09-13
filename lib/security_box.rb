# frozen_string_literal: true

require_relative "security_box/errors"
require_relative "security_box/configuration"
require_relative "security_box/result"
require_relative "security_box/runtime"
require_relative "security_box/sandbox"

module SecurityBox
  # Convenience shortcut:
  #   SecurityBox.eval("1 + 1")            # => Result
  #   SecurityBox.eval("1", fuel: 100)     # per-call overrides
  def self.eval(code, **overrides)
    Sandbox.new.eval(code, **overrides)
  end
end
