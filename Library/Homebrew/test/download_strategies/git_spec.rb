# typed: true
# frozen_string_literal: true

require "download_strategy"
require "socket"

RSpec.describe GitDownloadStrategy do
  subject(:strategy) { described_class.new(url, name, version) }

  let(:name) { "baz" }
  let(:url) { "https://github.com/homebrew/foo" }
  let(:version) { nil }
  let(:cached_location) { subject.cached_location }

  before do
    @commit_id = 1
    FileUtils.mkpath cached_location
  end

  describe "#clone_args" do
    it "terminates options before the URL" do
      expect(strategy.clone_args).to end_with("--end-of-options", url, cached_location.to_s)
    end
  end

  describe "#command_sandbox" do
    let(:home) { mktmpdir }

    before do
      allow(Sandbox).to receive(:isolate_operation?).and_return(true)
      allow(Dir).to receive(:home).with(ENV.fetch("USER")).and_return(home.to_s)
      allow(strategy).to receive(:fetching?).and_return(true)
      %w[.ssh .config/gh .config/git .subversion].each { |path| (home/path).mkpath }
      %w[.gitconfig .git-credentials .hgrc .cvspass .fossil].each { |path| (home/path).write("") }
    end

    it "does not grant unused credentials to an HTTPS download" do
      expect(strategy.command_sandbox.profile.rules.filter_map { |rule| rule.filter&.path if rule.allow })
        .not_to include(*%w[.ssh .config/gh .git-credentials .subversion .hgrc .cvspass .fossil].map do |path|
          (home/path).realpath.to_s
        end)
    end

    it "only grants the Git credential store when configured" do
      (home/".gitconfig").write("[credential]\n\thelper = store\n")

      expect(strategy.command_sandbox.profile.rules)
        .to include(have_attributes(allow: true, operation: "file-read*",
                                    filter: have_attributes(path: (home/".git-credentials").to_s)))
    end

    it "reads nested global includes and their credential helpers" do
      (home/".gitconfig").write("[include]\n\tpath = ~/.config/git/work config\n")
      (home/".config/git/work config").write("[include]\n\tpath = empty\n[credential]\n\thelper = store\n")
      (home/".config/git/empty").write("")

      expect(strategy.command_sandbox.profile.rules.filter_map { |rule| rule.filter&.path if rule.allow })
        .to include(*[".git-credentials", ".config/git/empty", ".config/git/work config"].map do |path|
          (home/path).to_s
        end)
    end

    it "uses the downloaded repository's context for conditional global includes" do
      system "git", "init", "--quiet", cached_location
      (home/".gitconfig").write <<~EOS
        [includeIf "gitdir:#{cached_location}/.git"]
          path = .config/git/work
        [includeIf "hasconfig:remote.*.url:#{url}"]
          path = .config/git/remote
      EOS
      (home/".config/git/work").write("[credential]\n\thelper = store\n")
      (home/".config/git/remote").write("[credential]\n\thelper = !gh auth git-credential\n")
      system "git", "-C", cached_location, "remote", "add", "origin", url

      expect(strategy.command_sandbox.profile.rules.filter_map { |rule| rule.filter&.path if rule.allow })
        .to include(*%w[.config/git/work .config/git/remote .git-credentials .config/gh].map do |path|
          (home/path).to_s
        end)
    end

    it "grants the configured credential store file instead of the default stores" do
      (home/".config/git/work credentials").write("")
      ["store --file ~/.config/git/work\\ credentials",
       "store --file='#{home}/.config/git/work credentials'"].each do |helper|
        system "git", "config", "--file", home/".gitconfig", "credential.helper", helper

        paths = strategy.command_sandbox.profile.rules.filter_map { |rule| rule.filter&.path if rule.allow }
        expect(paths).to include((home/".config/git/work credentials").to_s)
        expect(paths).not_to include((home/".git-credentials").to_s, (home/".config/git/credentials").to_s)
      end
    end

    it "does not derive credential grants from repository-local includes" do
      system "git", "init", "--quiet", cached_location
      (home/"local-config").write("[credential]\n\thelper = store\n")
      system "git", "-C", cached_location, "config", "include.path", (home/"local-config").to_s

      expect(strategy.command_sandbox.profile.rules.filter_map { |rule| rule.filter&.path if rule.allow })
        .not_to include((home/"local-config").to_s, (home/".git-credentials").to_s)
    end

    it "resolves relative credential stores from the clone or fetch working directory" do
      (home/".gitconfig").write("[credential]\n\thelper = store --file creds\n")
      (home/"creds").write("")
      (cached_location/"creds").write("")

      home.cd do
        expect(strategy.command_sandbox.profile.rules.filter_map { |rule| rule.filter&.path if rule.allow })
          .to include((home/"creds").to_s)
        system "git", "init", "--quiet", cached_location
        expect(strategy.command_sandbox.profile.rules.filter_map { |rule| rule.filter&.path if rule.allow })
          .to include((cached_location/"creds").to_s)
      end
    end

    it "does not grant credentials during local inspection" do
      allow(strategy).to receive(:fetching?).and_return(false)

      expect(strategy.command_sandbox.profile.rules.filter_map { |rule| rule.filter&.path if rule.allow })
        .not_to include((home/".gitconfig").to_s, (home/".ssh").to_s)
    end

    context "with SSH" do
      let(:url) { "git@git.example.com:org/private-repo.git" }
      let(:sandbox) { Sandbox.for_operation(write_paths: [cached_location], network_access: true) }
      let(:agent_rules) do
        strategy.command_sandbox.profile.rules.select { |rule| rule.allow && rule.operation == "network*" }
      end
      let(:agent_paths) { agent_rules.map { |rule| rule.filter&.path } }
      let(:agent_socket) { (home/"agent.sock").to_s }

      before do
        ENV.delete("SSH_AUTH_SOCK")
        (home/".ssh/config").write("IdentityAgent none\n")
        home.cd { UNIXServer.open("agent.sock", &:close) }
        (home/"Library/Group Containers").mkpath
        (home/"Library/Group Containers").cd do
          UNIXServer.open("agent-git-22.sock", &:close)
          UNIXServer.open("agent-git-2222.sock", &:close)
        end
        allow(Sandbox).to receive(:for_operation).and_return(sandbox)
        allow(sandbox).to receive(:capture) do |command, **options|
          SystemCommand.run(command, **options, args: ["-F", home/".ssh/config", *options.fetch(:args)])
        end
      end

      test_each(%w[
        git@git.example.com:org/private-repo.git
        git@[git.example.com:2222]:org/private-repo.git
        ssh://git@git.example.com:2222/org/private-repo.git
        git+ssh://git@git.example.com:2222/org/private-repo.git
        ssh+git://git@git.example.com:2222/org/private-repo.git
        git@[::1]:org/private-repo.git
        ssh://git@[::1]:2222/org/private-repo.git
      ]) do |ssh_url|
        context "with #{ssh_url}" do
          let(:url) { ssh_url }

          it "only permits the host's configured IdentityAgent socket" do
            ENV["SSH_AUTH_SOCK"] = agent_socket
            (home/".ssh/config").write <<~EOS
              Host git.example.com ::1
                IdentityAgent "${HOME}/Library/Group Containers/agent-%r-%p.sock"
              Host *
                IdentityAgent none
            EOS

            expect(agent_rules)
              .to contain_exactly(have_attributes(filter: have_attributes(
                path: "#{home}/Library/Group Containers/agent-git-#{url.include?(":2222") ? 2222 : 22}.sock",
                type: :literal,
              )))
          end
        end
      end

      test_each([nil, "SSH_AUTH_SOCK", "$SSH_AUTH_SOCK"]) do |identity_agent|
        it "uses SSH_AUTH_SOCK when IdentityAgent is #{identity_agent || "unset"}" do
          ENV["SSH_AUTH_SOCK"] = agent_socket
          (home/".ssh/config").write(identity_agent ? "IdentityAgent #{identity_agent}\n" : "")

          expect(agent_paths).to eq([agent_socket])
        end
      end

      test_each(["none", "$HOMEBREW_MISSING_SSH_AGENT"]) do |identity_agent|
        it "does not fall back to SSH_AUTH_SOCK for IdentityAgent #{identity_agent}" do
          ENV["SSH_AUTH_SOCK"] = agent_socket
          ENV.delete("HOMEBREW_MISSING_SSH_AGENT")
          (home/".ssh/config").write("IdentityAgent #{identity_agent}\n")

          expect(agent_rules).to be_empty
        end
      end

      test_each(["none", "SSH_AUTH_SOCK", "$SSH_AUTH_SOCK"]) do |identity_agent|
        it "does not grant a socket for #{identity_agent} without SSH_AUTH_SOCK" do
          (home/".ssh/config").write("IdentityAgent #{identity_agent}\n")

          expect(agent_rules).to be_empty
        end
      end

      it "permits an IdentityAgent socket from an environment variable" do
        ENV["HOMEBREW_SSH_AGENT"] = agent_socket
        (home/".ssh/config").write("IdentityAgent $HOMEBREW_SSH_AGENT\n")

        expect(agent_paths).to eq([agent_socket])
      end

      it "expands an included IdentityAgent path before checking the socket" do
        (home/".ssh/config").write("Include \"#{home}/.ssh/agent config\"\n")
        (home/".ssh/agent config").write <<~EOS
          IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        EOS

        allow(File).to receive(:realpath).and_call_original
        expect(File).to receive(:realpath)
          .with("#{Etc.getpwuid&.dir}/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
          .and_raise(Errno::ENOENT)

        strategy.command_sandbox
      end

      it "does not grant SSH_AUTH_SOCK when the SSH configuration cannot be read" do
        ENV["SSH_AUTH_SOCK"] = agent_socket
        allow(sandbox).to receive(:capture)
          .and_return(instance_double(SystemCommand::Result, success?: false,
                                                             stdout:   "identityagent #{home}/other.sock\n",
                                                             stderr:   "configuration unreadable"))

        expect(strategy).to receive(:odebug)
          .with("Skipping SSH agent access: ssh -G failed.", "configuration unreadable")
        expect(agent_rules).to be_empty
      end

      it "evaluates SSH configuration inside the download sandbox with the download environment" do
        ENV["SSH_AUTH_SOCK"] = agent_socket

        expect(sandbox).to receive(:capture)
          .with("ssh", args: ["-G", "--", "git@git.example.com"], must_succeed: false, print_stderr: false,
                       env: { "HOME" => home.to_s, "GIT_TERMINAL_PROMPT" => "0",
                              "SSH_AUTH_SOCK" => agent_socket })
          .and_return(instance_double(SystemCommand::Result, success?: true, stdout: "identityagent none\n"))

        strategy.command_sandbox
      end

      it "launches the SSH probe with the download sandbox profile", :needs_macos do
        allow(sandbox).to receive(:capture).and_call_original
        result = instance_double(SystemCommand::Result, success?: true, stdout: "identityagent none\n")
        command = instance_double(SystemCommand, run!: result, "sandbox_inheritance=": nil)
        allow(SystemCommand).to receive(:new).and_call_original
        expect(SystemCommand).to receive(:new)
          .with("/usr/bin/sandbox-exec",
                hash_including(args: ["-p", include("(deny file-read* (subpath #{home.to_s.inspect}))"),
                                      "ssh", "-G", "--", "git@git.example.com"]))
          .and_return(command)

        strategy.command_sandbox
      end

      test_each(%w[
        git;id@git.example.com:repo.git
        git@git.example.com;id:repo.git
        ssh://git;id@git.example.com/repo.git
        ssh://git%20user@git.example.com/repo.git
        git@../../x:repo.git
        https://git.example.com/repo.git
        git://git.example.com/repo.git
        file:///tmp/repo.git
        /tmp/repo.git
      ]) do |unprobed_url|
        context "with #{unprobed_url}" do
          let(:url) { unprobed_url }

          it "does not probe SSH configuration or grant agent access" do
            ENV["SSH_AUTH_SOCK"] = agent_socket
            expect(sandbox).not_to receive(:capture)

            expect(agent_rules).to be_empty
          end
        end
      end

      test_each(["ssh://git@[fe80::1%en0]/repo.git", "ssh://git@example.com:bad/repo.git",
                 "ssh://git user@example.com/repo.git"]) do |invalid_uri|
        context "with #{invalid_uri}" do
          let(:url) { invalid_uri }

          it "does not grant agent access when Ruby cannot parse the URI" do
            ENV["SSH_AUTH_SOCK"] = agent_socket

            expect(strategy).to receive(:odebug).with("Skipping SSH agent access: unsupported SSH destination.")
            expect(agent_rules).to be_empty
          end
        end
      end

      context "with a parent directory as the hostname" do
        let(:url) { "git@..:repo.git" }

        it "does not grant a socket through path traversal" do
          (home/"agents").mkpath
          (home/".ssh/config").write("IdentityAgent #{home}/agents/%h/agent.sock\n")

          expect(agent_rules).to be_empty
        end
      end

      it "does not grant relative socket paths" do
        (home/".ssh/config").write("IdentityAgent agent.sock\n")

        expect(agent_rules).to be_empty
      end

      it "does not grant missing sockets" do
        ENV["SSH_AUTH_SOCK"] = agent_socket
        (home/".ssh/config").write("IdentityAgent #{home}/missing.sock\n")

        expect(agent_rules).to be_empty
      end

      it "does not grant regular files as sockets" do
        (home/"agent.sock").unlink
        (home/"agent.sock").write("")
        (home/".ssh/config").write("IdentityAgent #{home}/agent.sock\n")

        expect(agent_rules).to be_empty
      end

      it "does not grant sockets owned by another user" do
        (home/".ssh/config").write("IdentityAgent #{home}/agent.sock\n")
        allow(File).to receive(:owned?).with(agent_socket).and_return(false)

        expect(agent_rules).to be_empty
      end

      it "validates and grants the same resolved socket if a symlink changes" do
        (home/".ssh/agent.sock").make_symlink(home/"agent.sock")
        (home/".ssh/config").write("IdentityAgent #{home}/.ssh/agent.sock\n")
        allow(File).to receive(:owned?).and_call_original
        allow(File).to receive(:owned?).with(agent_socket) do
          (home/".ssh/agent.sock").unlink
          (home/".ssh/agent.sock").make_symlink(home/"Library/Group Containers/agent-git-22.sock")
          true
        end

        expect([agent_paths, (home/".ssh/agent.sock").readlink])
          .to eq([[agent_socket], home/"Library/Group Containers/agent-git-22.sock"])
      end

      test_each([Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR,
                 Errno::EPERM, Errno::ENAMETOOLONG, Errno::EIO, Errno::ESTALE, ArgumentError]) do |error|
        it "does not grant sockets that cannot be resolved due to #{error}" do
          (home/".ssh/config").write("IdentityAgent #{home}/agent.sock\n")
          allow(File).to receive(:realpath).and_call_original
          allow(File).to receive(:realpath).with(agent_socket).and_raise(error)

          expect(strategy).to receive(:odebug)
            .with("Skipping SSH agent access: cannot resolve #{agent_socket.inspect}.", kind_of(error))
          expect(agent_rules).to be_empty
        end
      end
    end
  end

  describe "#ref?" do
    it "terminates options before the ref" do
      expect(strategy).to receive(:silent_command)
        .with(
          "git",
          args: ["--git-dir", cached_location/".git", "rev-parse", "-q", "--verify", "--end-of-options",
                 "master^{commit}"],
        )
        .and_return(instance_double(SystemCommand::Result, success?: true))

      strategy.ref?
    end
  end

  def git_commit_all
    system "git", "add", "--all"
    # Allow instance variables here to have nice commit messages.
    # rubocop:disable RSpec/InstanceVariable
    system "git", "commit", "-m", "commit number #{@commit_id}"
    @commit_id += 1
    # rubocop:enable RSpec/InstanceVariable
  end

  def setup_git_repo
    system "git", "-c", "init.defaultBranch=master", "init"
    system "git", "remote", "add", "origin", "https://github.com/Homebrew/homebrew-foo"
    FileUtils.touch "README"
    git_commit_all
  end

  describe "#source_modified_time" do
    it "returns the right modification time" do
      cached_location.cd do
        setup_git_repo
      end
      expect(strategy.source_modified_time.to_i).to eq(1_485_115_153)
    end

    it "nulls the global Git config so sandboxed staging reads do not fail" do
      expect(strategy).to receive(:system_command)
        .with(
          "git",
          args:         ["--git-dir", cached_location/".git", "show", "-s", "--format=%cD"],
          env:          { "GIT_TERMINAL_PROMPT" => "0", "GIT_CONFIG_GLOBAL" => File::NULL },
          print_stderr: false,
        )
        .and_return(instance_double(SystemCommand::Result, success?: true,
                                                           stdout:   "Fri, 12 Jun 2026 06:12:11 -0700"))

      expect(strategy.source_modified_time).to eq(Time.parse("Fri, 12 Jun 2026 06:12:11 -0700"))
    end

    it "raises the underlying Git error instead of a Time parsing error on failure" do
      allow(strategy).to receive(:system_command)
        .and_return(instance_double(SystemCommand::Result, success?: false,
                                                           stdout: "", stderr: "fatal: unable to access"))

      expect { strategy.source_modified_time }.to raise_error(/fatal: unable to access/)
    end
  end

  describe "#last_commit" do
    specify "returns the short hash of the last commit" do
      cached_location.cd do
        setup_git_repo
        FileUtils.touch "LICENSE"
        git_commit_all
      end
      expect(strategy.last_commit).to eq("f68266e")
    end

    it "nulls the global Git config so sandboxed staging reads do not fail" do
      expect(strategy).to receive(:system_command)
        .with(
          "git",
          args:         ["--git-dir", cached_location/".git", "rev-parse", "--short=7", "HEAD"],
          env:          { "GIT_TERMINAL_PROMPT" => "0", "GIT_CONFIG_GLOBAL" => File::NULL },
          print_stderr: false,
        )
        .and_return(instance_double(SystemCommand::Result, stdout: "f68266e\n"))

      expect(strategy.last_commit).to eq("f68266e")
    end
  end

  describe "#fetch_last_commit" do
    let(:url) { "file://#{remote_repo}" }
    let(:version) { Version.new("HEAD") }
    let(:remote_repo) { HOMEBREW_PREFIX/"remote_repo" }

    before { remote_repo.mkpath }

    after { FileUtils.rm_rf remote_repo }

    it "fetches the hash of the last commit" do
      remote_repo.cd do
        setup_git_repo
        FileUtils.touch "LICENSE"
        git_commit_all
      end

      expect(strategy.fetch_last_commit).to eq("f68266e")
    end
  end
end
