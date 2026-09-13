# frozen_string_literal: true

RSpec.describe "SecurityBox.warmup" do
  it "populates the runtime caches (engine + module) ahead of the first eval" do
    SecurityBox.warmup

    engines = SecurityBox::Runtime.instance_variable_get(:@engines)
    modules = SecurityBox::Runtime.instance_variable_get(:@modules)

    expect(engines).not_to be_empty
    expect(modules).not_to be_empty
  end

  it "reuses the cached module on subsequent calls" do
    SecurityBox.warmup
    allow(Wasmtime::Module).to receive(:from_file).and_call_original

    SecurityBox.warmup

    expect(Wasmtime::Module).not_to have_received(:from_file)
  end

  it "does not change eval behavior" do
    SecurityBox.warmup
    result = SecurityBox.eval("1 + 1")

    expect(result).to be_ok
    expect(result.value).to eq(2)
  end
end
