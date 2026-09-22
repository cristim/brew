# typed: strict
# frozen_string_literal: true

require "open3"

RSpec.describe "package postinstall", type: :system do
  # Keep each Sorbet signature with its let declaration.
  # rubocop:disable RSpec/ScatteredLet
  sig { returns(Pathname) }
  let(:test_root) { mktmpdir }

  sig { returns(Pathname) }
  let(:prefix) { test_root/"prefix" }

  sig { returns(Integer) }
  let(:install_uid) { 501 }

  sig { returns(String) }
  let(:install_groups) { "staff admin" }

  sig { returns(T::Boolean) }
  let(:developer_tools) { true }

  sig { returns(T::Boolean) }
  let(:sudo_available) { true }

  sig { returns(Integer) }
  let(:caller_uid) { 0 }

  sig { returns(String) }
  let(:developer_dir) { "#{test_root}/Developer Tools" }

  sig { returns(Pathname) }
  let(:commands) { test_root/"commands" }

  sig { returns([String, String, Process::Status]) }
  let(:result) do
    Open3.capture3("/bin/bash", "-c", <<~SH)
      id() {
        if [[ "$#" == 1 && "$1" == -u ]]; then echo #{caller_uid}; return; fi
        case "$1" in
          -Gn) echo "#{install_groups}" ;;
          -gn) echo brew-users ;;
          *) echo #{install_uid} ;;
        esac
      }
      chmod() { :; }
      chown() { echo "chown $*" >> "#{commands}"; }
      xcode-select() {
        [[ "#{developer_tools}" == true ]] || return 1
        echo "#{developer_dir}"
      }
      git() {
        echo "git $*" >> "#{commands}"
        if [[ "$*" == *" tag "* ]]; then echo 7.0.3; fi
      }
      command() {
        if [[ "$*" == "-v sudo" && "#{sudo_available}" == false ]]; then return 1; fi
        builtin command "$@"
      }
      sudo() {
        [[ "#{sudo_available}" == true ]] || return 127
        echo "sudo $*" >> "#{commands}"
        if [[ "$*" == *" git "* || "$*" == *"/git "* ]]; then
          [[ "#{developer_tools}" == true ]] || return 1
          if [[ "$*" == *" tag "* ]]; then echo 7.0.3; fi
        else
          shift 2
          "$@"
        fi
      }
      login() {
        echo "login $*" >> "#{commands}"
        [[ "$1 $2 $3 $4" == "-f -l -q pkg-user" ]] || return 1
        shift 4
        if [[ "$*" == *"/git "* ]]; then
          if [[ "$*" == *" tag "* ]]; then echo 7.0.3; fi
        else
          "$@"
        fi
      }
      source "#{test_root}/postinstall" "" "#{prefix}"
    SH
  end
  # rubocop:enable RSpec/ScatteredLet

  before do
    (prefix/"bin").mkpath
    (prefix/"cache_api").mkpath
    (prefix/"cache_api/formula.json").write "{}"
    (test_root/"Developer Tools/usr/bin").mkpath
    FileUtils.touch test_root/"Developer Tools/usr/bin/git"
    (test_root/"Developer Tools/usr/bin/git").chmod(0755)
    commands.write ""
    (test_root/"postinstall").write(
      (HOMEBREW_LIBRARY_PATH.parent.parent/"package/scripts/postinstall").read
        .gsub("/etc/paths.d", "#{test_root}/paths.d"),
    )
    (test_root/"macos_user.sh").write <<~SH
      homebrew-package-user() { echo pkg-user; }
      homebrew-user-home() { echo "#{test_root}"; }
    SH
  end

  it "runs Git as the install user after setting ownership" do
    _, stderr, status = result
    git_command = "sudo -u pkg-user /usr/bin/env HOME=#{prefix} GIT_CONFIG_GLOBAL=/dev/null " \
                  "PATH=/usr/bin:/bin:/usr/sbin:/sbin " \
                  "#{test_root}/Developer Tools/usr/bin/git -c core.hooksPath=/dev/null -C #{prefix}"

    expect([status.exitstatus, stderr, commands.read.lines(chomp: true)]).to eq([
      0, "", [
        "chown -R pkg-user:admin .",
        "#{git_command} tag --list --sort=-version:refname",
        "#{git_command} checkout --force -B stable",
        "#{git_command} reset --hard 7.0.3",
        "#{git_command} clean -f -d",
        "sudo -u pkg-user mkdir -vp #{test_root}/Library/Caches/Homebrew/api",
        "sudo -u pkg-user cp -vpR #{prefix}/cache_api/. #{test_root}/Library/Caches/Homebrew/api",
      ]
    ])
  end

  context "when developer tools are not installed" do
    sig { returns(T::Boolean) }
    let(:developer_tools) { false }

    it "installs and seeds the API cache without invoking Git" do
      _, stderr, status = result

      expect([status.exitstatus, stderr, (test_root/"Library/Caches/Homebrew/api/formula.json").file?]).to eq([
        0, "", true
      ])
    end
  end

  context "when sudo is unavailable" do
    sig { returns(T::Boolean) }
    let(:sudo_available) { false }

    it "runs Git and seeds the cache through login as the install user" do
      _, stderr, status = result

      expect([
        status.exitstatus, stderr,
        commands.read.lines.drop(1).map { |command| command.split.first(5).join(" ") },
        (test_root/"Library/Caches/Homebrew/api/formula.json").file?
      ]).to eq([0, "", Array.new(6, "login -f -l -q pkg-user"), true])
    end

    context "when developer tools are also unavailable" do
      sig { returns(T::Boolean) }
      let(:developer_tools) { false }

      it "installs and seeds the API cache" do
        _, stderr, status = result

        expect([status.exitstatus, stderr, (test_root/"Library/Caches/Homebrew/api/formula.json").file?]).to eq([
          0, "", true
        ])
      end
    end

    context "when the caller is not root" do
      sig { returns(Integer) }
      let(:caller_uid) { 502 }

      it "rejects account switching" do
        _, stderr, status = result

        expect([status.exitstatus, stderr, commands.read]).to eq([
          1, "Switching to the Homebrew installation user without sudo requires root.\n", ""
        ])
      end
    end
  end

  context "when xcode-select points to the root directory" do
    sig { returns(String) }
    let(:developer_dir) { "/" }

    it "does not invoke the system Git stub" do
      result

      expect(commands.read).not_to include("/usr/bin/git")
    end
  end

  context "when the install user has UID 0" do
    sig { returns(Integer) }
    let(:install_uid) { 0 }

    it "rejects the account before changing ownership or running Git" do
      stdout, _, status = result

      expect([status.exitstatus, stdout.lines.last, commands.read]).to eq([
        1, "The Homebrew installation user must not be root.\n", ""
      ])
    end
  end

  context "when the install user is not an administrator" do
    sig { returns(String) }
    let(:install_groups) { "brew-users other-group" }

    it "uses the install user's custom primary group" do
      result

      expect(commands.read.lines.first).to eq("chown -R pkg-user:brew-users .\n")
    end
  end
end
