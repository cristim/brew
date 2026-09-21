# typed: true
# frozen_string_literal: true

require "open3"

# This tests Bash startup code rather than a Ruby class.
RSpec.describe "sudo detection" do # rubocop:disable RSpec/DescribeClass
  let(:sudo) { mktmpdir/"sudo" }
  let(:sudo_log) { sudo.dirname/"calls" }
  let(:unavailable) do
    _, _, status = Open3.capture3("/bin/bash", "-c", <<~SH, "--", sudo.to_s)
      SUDO="$1"
      #{(HOMEBREW_LIBRARY_PATH/"brew.sh").read.split("# Ruby honours this result").fetch(1)
                                          .split("# Remove internal variables").fetch(0).lines.drop(1).join}
      [[ -n "$HOMEBREW_NO_SUDO" ]]
    SH
    status.success?
  end

  before do
    ENV.delete("HOMEBREW_NO_SUDO")
    sudo.write <<~SH
      #!/bin/bash
      printf '%s\n' "$*" >> "#{sudo_log}"
      if [[ "$*" == --reset-timestamp ]]; then
        printf '%s\n' "$SUDO_TEST_RESET_OUTPUT" >&2
        exit "${SUDO_TEST_RESET_STATUS:-0}"
      fi
      [[ "$*" == "-n -k -l" && "$LC_ALL" == C ]] || exit 2
      printf '%s\n' "$SUDO_TEST_OUTPUT" >&2
      exit "${SUDO_TEST_STATUS:-1}"
    SH
    sudo.chmod(0755)
  end

  it "honours the explicit setting without probing sudo" do
    ENV["HOMEBREW_NO_SUDO"] = "1"
    ENV["SUDO_TEST_STATUS"] = "0"

    expect([unavailable, sudo_log.exist?]).to eq([true, false])
  end

  it "detects a missing sudo executable" do
    sudo.unlink

    expect(unavailable).to be true
  end

  it "recognises an explicit policy denial" do
    ENV["SUDO_TEST_OUTPUT"] = "Sorry, user brewer may not run sudo on localhost."

    expect([unavailable, sudo_log.read.lines(chomp: true)])
      .to eq([true, ["--reset-timestamp", "-n -k -l"]])
  end

  it "does not mistake a password requirement for a policy denial" do
    ENV["SUDO_TEST_OUTPUT"] = "sudo: a password is required"

    expect(unavailable).to be false
  end

  it "preserves sudo when listing privileges succeeds" do
    ENV["SUDO_TEST_STATUS"] = "0"

    expect(unavailable).to be false
  end

  it "preserves sudo when the failure is unknown" do
    ENV["SUDO_TEST_OUTPUT"] = "sudo: unable to resolve host localhost"

    expect(unavailable).to be false
  end

  test_each([
    'sudo: The "no new privileges" flag is set, which prevents sudo from running as root.',
    "sudo: effective uid is not 0, is sudo installed setuid root?",
    "sudo: /usr/bin/sudo must be owned by uid 0 and have the setuid bit set",
  ]) do |message|
    it "detects a fatal startup error from resetting the timestamp: #{message}" do
      ENV["SUDO_TEST_RESET_OUTPUT"] = message
      ENV["SUDO_TEST_RESET_STATUS"] = "1"
      ENV["SUDO_TEST_STATUS"] = "0"

      expect([unavailable, sudo_log.read.lines(chomp: true)]).to eq([true, ["--reset-timestamp"]])
    end

    it "detects a fatal startup error from listing privileges: #{message}" do
      ENV["SUDO_TEST_OUTPUT"] = message

      expect(unavailable).to be true
    end
  end

  it "does not treat an unsupported timestamp reset as lack of sudo access" do
    ENV["SUDO_TEST_RESET_OUTPUT"] = "sudo: policy plugin example does not support the -k/-K options"
    ENV["SUDO_TEST_RESET_STATUS"] = "1"
    ENV["SUDO_TEST_STATUS"] = "0"

    expect([unavailable, sudo_log.read.lines(chomp: true)])
      .to eq([false, ["--reset-timestamp", "-n -k -l"]])
  end
end
