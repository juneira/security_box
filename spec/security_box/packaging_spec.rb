# frozen_string_literal: true

RSpec.describe "gem packaging" do
  # Evaluates the real gemspec; spec_helper guarantees the sandbox image exists
  # before the suite runs, so the file list must include it.
  let(:gemspec) { Gem::Specification.load("security_box.gemspec") }

  it "matches the library version" do
    expect(gemspec.name).to eq("security_box")
    expect(gemspec.version.to_s).to eq(SecurityBox::VERSION)
  end

  it "requires Ruby >= 4.0 and is MIT licensed" do
    expect(gemspec.required_ruby_version.to_s).to eq(">= 4.0")
    expect(gemspec.license).to eq("MIT")
  end

  it "ships the sandbox image and library sources" do
    expect(gemspec.files).to include("lib/security_box/assets/security_box.wasm")
    expect(gemspec.files).to include("lib/security_box.rb")
    expect(gemspec.files).to include("lib/security_box/guest/main.rb")
    expect(gemspec.files).to include("lib/security_box/sandbox.rb")
  end

  it "does not ship development artifacts" do
    expect(gemspec.files).not_to include(match(%r{^spec/}))
    expect(gemspec.files).not_to include(match(%r{^build/}))
    expect(gemspec.files).not_to include("Gemfile", "Gemfile.lock", "Rakefile")
  end

  it "declares wasmtime as the only runtime dependency" do
    expect(gemspec.dependencies.map(&:name)).to eq(["wasmtime"])
    expect(gemspec.dependencies.map(&:type)).to eq([:runtime])
  end

  it "exposes metadata URIs" do
    expect(gemspec.metadata["source_code_uri"]).to eq(gemspec.homepage)
    expect(gemspec.metadata["changelog_uri"]).to be_a(String)
  end
end