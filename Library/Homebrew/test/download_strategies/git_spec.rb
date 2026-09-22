# typed: true
# frozen_string_literal: true

require "download_strategy"

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

  describe "#fetch" do
    it "aborts the download if Git cannot be installed" do
      allow(Utils::Git).to receive(:ensure_installed!).and_raise("Git installation failed")
      allow(strategy).to receive(:repo_valid?).and_return(true)
      allow(strategy).to receive(:update)

      expect { strategy.fetch }.to raise_error("Git installation failed")
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
