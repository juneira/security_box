# frozen_string_literal: true

require "calculator"

RSpec.describe Calculator do
  describe ".add" do
    it "adds two numbers" do
      expect(Calculator.add(2, 3)).to eq(5)
    end
  end

  describe ".divide" do
    it "divides two numbers" do
      expect(Calculator.divide(10, 4)).to eq(2.5)
    end

    it "rejects division by zero" do
      expect { Calculator.divide(1, 0) }.to raise_error(ArgumentError, "division by zero")
    end
  end

  describe "a deliberately failing example" do
    it "shows how RSpec failures are reported" do
      expect(Calculator.add(2, 3)).to eq(6)
    end
  end
end