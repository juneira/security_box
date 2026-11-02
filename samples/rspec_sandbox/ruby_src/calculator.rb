# frozen_string_literal: true

module Calculator
  module_function

  def add(a, b)
    a + b
  end

  def divide(a, b)
    raise ArgumentError, "division by zero" if b.zero?

    a.fdiv(b)
  end
end