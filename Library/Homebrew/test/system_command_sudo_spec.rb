# typed: strict
# frozen_string_literal: true

require "system_command"

RSpec.describe SystemCommand do
  it "rejects sudo commands when sudo is disabled" do
    ENV["HOMEBREW_NO_SUDO"] = "1"

    expect { described_class.new("true", sudo: true).command }
      .to raise_error(ErrorDuringExecution, /sudo is disabled by HOMEBREW_NO_SUDO/)
  end

  it "preserves sudo commands when sudo is enabled" do
    ENV.delete("HOMEBREW_NO_SUDO")

    expect(described_class.new("true", sudo: true).command).to eq(["/usr/bin/sudo", "-E", "--", "true"])
  end

  it "tries optional elevation without sudo first" do
    ENV.delete("HOMEBREW_NO_SUDO")

    expect(described_class.run!("/usr/bin/true", sudo: nil).success?).to be true
  end

  it "retries a failed optional operation with sudo" do
    ENV.delete("HOMEBREW_NO_SUDO")
    attempts = []
    allow(described_class).to receive(:new) do |_, **options|
      attempts << options.fetch(:sudo)
      instance_double(described_class, run!: instance_double(SystemCommand::Result, success?: options.fetch(:sudo)))
    end

    described_class.run("chmod", sudo: nil)

    expect(attempts).to eq([false, true])
  end

  it "keeps the original failure when optional elevation is disabled" do
    ENV["HOMEBREW_NO_SUDO"] = "1"

    expect { described_class.run!("/usr/bin/false", sudo: nil, print_stderr: false) }
      .to raise_error(ErrorDuringExecution, %r{/usr/bin/false})
  end
end
