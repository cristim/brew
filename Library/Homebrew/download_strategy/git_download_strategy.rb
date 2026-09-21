# typed: strict
# frozen_string_literal: true

require "uri"
require "utils/timer"

# Strategy for downloading a Git repository.
#
# @api public
class GitDownloadStrategy < VCSDownloadStrategy
  MINIMUM_COMMIT_HASH_LENGTH = 7
  MAX_SSH_PORT = 65_535

  sig { params(url: String, name: String, version: T.nilable(T.any(String, Version)), meta: T.untyped).void }
  def initialize(url, name, version, **meta)
    # Needs to be before the call to `super`, as the VCSDownloadStrategy's
    # constructor calls `cache_tag` and sets the cache path.
    @only_path = meta[:only_path]

    if @only_path.present?
      # "Cone" mode of sparse checkout requires patterns to be directories
      @only_path = T.let("/#{@only_path}", String) unless @only_path.start_with?("/")
      @only_path = T.let("#{@only_path}/", String) unless @only_path.end_with?("/")
    end

    super
    @ref_type ||= T.let(:branch, T.nilable(Symbol))
    @ref ||= T.let("master", T.untyped)
  end

  # Returns the most recent modified time for all files in the current working directory after stage.
  #
  # @api public
  sig { override.returns(Time) }
  def source_modified_time
    result = system_command("git", args: ["--git-dir", git_dir, "show", "-s", "--format=%cD"],
                                   env:  local_git_env, print_stderr: false)
    raise "Failed to read the Git commit time:\n#{result.stderr}" unless result.success?

    Time.parse(result.stdout)
  end

  sig { override.returns(T.nilable(String)) }
  def source_revision = current_revision.presence

  # Return last commit's unique identifier for the repository if fetched locally.
  #
  # @api public
  sig { override.returns(String) }
  def last_commit
    args = ["--git-dir", git_dir, "rev-parse", "--short=#{MINIMUM_COMMIT_HASH_LENGTH}", "HEAD"]
    @last_commit ||= system_command("git", args:, env: local_git_env, print_stderr: false).stdout.chomp.presence
    @last_commit || ""
  end

  sig { returns(T::Boolean) }
  def ref?
    silent_command("git",
                   args: ["--git-dir", git_dir, "rev-parse", "-q", "--verify", "--end-of-options",
                          "#{@ref}^{commit}"])
      .success?
  end

  sig { returns(T::Array[String]) }
  def clone_args
    args = %w[clone]

    case @ref_type
    when :branch, :tag
      args << "--branch" << @ref
    end

    args << "--no-checkout" << "--filter=blob:none" if partial_clone_sparse_checkout?

    args << "--config" << "advice.detachedHead=false" # Silences “detached head” warning.
    args << "--config" << "core.fsmonitor=false" # Prevent `fsmonitor` from watching this repository.
    args << "--end-of-options" << @url << cached_location.to_s
  end

  private

  sig { override.params(sandbox: Sandbox).void }
  def allow_fetch_credentials(sandbox)
    return unless supports_authentication?

    home = Pathname(Dir.home(ENV.fetch("USER")))
    config_home = Pathname(ENV.fetch("XDG_CONFIG_HOME", (home/".config").to_s))
    if (global_config = ENV.fetch("GIT_CONFIG_GLOBAL", nil))
      [Pathname(global_config)]
    else
      [home/".gitconfig", config_home/"git/config"]
    end.each { |path| sandbox.allow_read_if_exists(path:) }

    # Conditional includes need the repository context, even before its first clone.
    cached_location.mkpath
    SystemCommand.run("git", args: ["--git-dir", git_dir, "config", "--includes", "--null",
                                    "--show-scope", "--show-origin", "--list"],
                             env: { "HOME" => home.to_s }, print_stderr: false)
                 .stdout.split("\0").each_slice(3) do |scope, origin, entry|
      # Repository-local configuration must not authorise additional home access.
      next if scope != "global" || !origin&.start_with?("file:") || !entry

      path = Pathname(origin.delete_prefix("file:")).expand_path
      sandbox.allow_read_if_exists(path:)
      key, value = entry.split("\n", 2)
      next if value.nil?

      if key&.match?(/\Ainclude(?:if\..*)?\.path\z/)
        # Empty include files have no entries from which Git can report their origin.
        sandbox.allow_read_if_exists(path: Pathname(value.sub(%r{\A~/}, "#{home}/")).expand_path(path.dirname))
      elsif !ssh? && key&.match?(/\Acredential(?:\..*)?\.helper\z/)
        if value.match?(/\Astore(?:\s|\z)/)
          options = value.shellsplit
          file = options.each_with_index.filter_map do |option, index|
            next options[index + 1] if option == "--file"

            option.delete_prefix("--file=") if option.start_with?("--file=")
          end.last
          paths = if file
            # Clone starts in the invocation directory; fetch runs in the cached repository.
            [Pathname(file.sub(%r{\A~/}, "#{home}/"))
              .expand_path(git_dir.directory? ? cached_location : Pathname.pwd)]
          else
            [home/".git-credentials", config_home/"git/credentials"]
          end
          paths.each { |store| sandbox.allow_read_if_exists(path: store) }
        elsif value.match?(/\bgh\s+auth\s+git-credential\b/)
          sandbox.allow_read_if_exists(path: ENV.fetch("GH_CONFIG_DIR", (config_home/"gh").to_s), type: :subpath)
        end
      end
    end

    return unless ssh?

    sandbox.allow_read_if_exists(path: home/".ssh", type: :subpath)

    ssh_args = ["-G"]
    destination = if @url.include?("://")
      scheme, _, authority = @url.split("/")
      uri = begin
        URI("#{scheme}//#{authority}")
      rescue URI::InvalidURIError
        nil
      end
      if uri
        ssh_args += ["-p", uri.port.to_s] if uri.port
        [uri.user, uri.hostname].compact.join("@")
      end
    else
      host = @url[%r{\A(?:[^@/]+@)?(?:\[[^\]]+\]|[^:]+)}]&.delete("[]")
      _, hostname, port = host&.match(/\A([^:]+):(\d+)\z/).to_a
      if port && port.to_i <= MAX_SSH_PORT
        ssh_args += ["-p", port]
        hostname
      else
        host
      end
    end

    # The URL is untrusted; SSH configuration is trusted. Validate substitutions and paths.
    # Sandbox processes can use the selected agent for other destinations. Agent-side
    # destination constraints or confirmation (ssh-add -h/-c) limit this.
    unless destination&.match?(/\A(?:[a-zA-Z0-9._-]+@)?[a-zA-Z0-9._:-]+\z/)
      return odebug("Skipping SSH agent access: unsupported SSH destination.")
    end

    # Match exec must run inside the sandbox, with the same environment as the download.
    config = sandbox.capture("ssh", args: [*ssh_args, "--", destination], env:,
                                    must_succeed: false, print_stderr: false)
    return odebug("Skipping SSH agent access: ssh -G failed.", config.stderr) unless config.success?

    _, socket = config.stdout.match(/^identityagent (.+)$/).to_a
    socket = "$SSH_AUTH_SOCK" if socket.nil? || socket == "SSH_AUTH_SOCK"
    return odebug("Skipping SSH agent access: IdentityAgent is none.") if socket == "none"

    if socket.start_with?("$")
      variable = socket.delete_prefix("$")
      socket = ENV.fetch(variable, nil)
      return odebug("Skipping SSH agent access: #{variable.inspect} is unset or empty.") if socket.blank?
    end
    return odebug("Skipping SSH agent access: #{socket.inspect} is not absolute.") unless socket.start_with?("/")
    if socket.split("/").include?("..")
      return odebug("Skipping SSH agent access: #{socket.inspect} contains parent directory traversal.")
    end

    begin
      socket = File.realpath(socket)
    rescue SystemCallError, ArgumentError => e
      return odebug("Skipping SSH agent access: cannot resolve #{socket.inspect}.", e)
    end
    return odebug("Skipping SSH agent access: #{socket.inspect} is not a socket.") unless File.socket?(socket)
    return odebug("Skipping SSH agent access: #{socket.inspect} is not owned by you.") unless File.owned?(socket)

    sandbox.allow_network(path: socket)
  end

  # Local paths and the native git:// transport do not use credentials.
  sig { returns(T::Boolean) }
  def supports_authentication?
    ssh? || @url.start_with?("http://", "https://")
  end

  # Git accepts both SSH URLs and scp-style user@host:path addresses.
  sig { returns(T::Boolean) }
  def ssh?
    @url.match?(%r{\A(?:(?:ssh|git\+ssh|ssh\+git)://|[^/]+:(?!//))})
  end

  # Read user Git config so credential helpers work for private downloads,
  # but never block on an interactive credential prompt.
  sig { override.returns(T::Hash[String, String]) }
  def env
    { "GIT_TERMINAL_PROMPT" => "0" }.tap do |env|
      if fetching? && Sandbox.isolate_operation? && supports_authentication?
        env["HOME"] = Dir.home(ENV.fetch("USER"))
        if ssh? && (socket = ENV.fetch("SSH_AUTH_SOCK", nil))
          env["SSH_AUTH_SOCK"] = socket
        end
      end
    end
  end

  # Local, read-only repository inspections (`git --git-dir … rev-parse`/`show`)
  # can run while staging inside the sandbox, where reading the user's global Git
  # config is denied and makes Git exit. Null it here, unlike the download-time
  # commands that read it for credential helpers.
  sig { returns(T::Hash[String, String]) }
  def local_git_env
    require "utils/git"
    env.merge(Utils::Git.no_global_config_env)
  end

  sig { override.returns(String) }
  def cache_tag
    if partial_clone_sparse_checkout?
      "git-sparse"
    else
      "git"
    end
  end

  sig { returns(Integer) }
  def cache_version
    0
  end

  sig { override.params(timeout: T.nilable(Time)).void }
  def update(timeout: nil)
    config_repo
    update_repo(timeout:)
    checkout(timeout:)
    reset
    update_submodules(timeout:) if submodules?
  end

  sig { returns(T::Boolean) }
  def shallow_dir?
    (git_dir/"shallow").exist?
  end

  sig { returns(Pathname) }
  def git_dir
    cached_location/".git"
  end

  sig { override.returns(String) }
  def current_revision
    system_command("git", args: ["--git-dir", git_dir, "rev-parse", "-q", "--verify", "HEAD"],
                          env: local_git_env, print_stderr: false).stdout.strip
  end

  sig { override.returns(T::Boolean) }
  def repo_valid?
    silent_command("git", args: ["-C", cached_location, "status", "-s"]).success?
  end

  sig { returns(T::Boolean) }
  def submodules?
    (cached_location/".gitmodules").exist?
  end

  sig { returns(T::Boolean) }
  def partial_clone_sparse_checkout?
    return false if @only_path.blank?

    require "utils/git"
    Utils::Git.supports_partial_clone_sparse_checkout?
  end

  sig { returns(String) }
  def refspec
    case @ref_type
    when :branch then "+refs/heads/#{@ref}:refs/remotes/origin/#{@ref}"
    when :tag    then "+refs/tags/#{@ref}:refs/tags/#{@ref}"
    else              default_refspec
    end
  end

  sig { returns(String) }
  def default_refspec
    # https://git-scm.com/book/en/v2/Git-Internals-The-Refspec
    "+refs/heads/*:refs/remotes/origin/*"
  end

  sig { void }
  def config_repo
    command! "git",
             args:  ["config", "remote.origin.url", @url],
             chdir: cached_location
    command! "git",
             args:  ["config", "remote.origin.fetch", refspec],
             chdir: cached_location
    command! "git",
             args:  ["config", "remote.origin.tagOpt", "--no-tags"],
             chdir: cached_location
    command! "git",
             args:  ["config", "advice.detachedHead", "false"],
             chdir: cached_location
    command! "git",
             args:  ["config", "core.fsmonitor", "false"],
             chdir: cached_location

    return unless partial_clone_sparse_checkout?

    command! "git",
             args:  ["config", "origin.partialclonefilter", "blob:none"],
             chdir: cached_location
    configure_sparse_checkout
  end

  sig { params(timeout: T.nilable(Time)).void }
  def update_repo(timeout: nil)
    return if @ref_type != :branch && ref?

    # Convert any shallow clone to full clone
    if shallow_dir?
      command! "git",
               args:    ["fetch", "origin", "--unshallow"],
               chdir:   cached_location,
               timeout: Utils::Timer.remaining(timeout)
    else
      command! "git",
               args:    ["fetch", "origin"],
               chdir:   cached_location,
               timeout: Utils::Timer.remaining(timeout)
    end
  end

  sig { override.params(timeout: T.nilable(Time)).void }
  def clone_repo(timeout: nil)
    command! "git",
             args:    clone_args,
             timeout: Utils::Timer.remaining(timeout)

    command! "git",
             args:    ["config", "homebrew.cacheversion", cache_version],
             chdir:   cached_location,
             timeout: Utils::Timer.remaining(timeout)

    configure_sparse_checkout if partial_clone_sparse_checkout?

    checkout(timeout:)
    update_submodules(timeout:) if submodules?
  end

  sig { params(timeout: T.nilable(Time)).void }
  def checkout(timeout: nil)
    ohai "Checking out #{@ref_type} #{@ref}" if @ref
    command! "git", args: ["checkout", "-f", @ref, "--"], chdir: cached_location,
                    timeout: Utils::Timer.remaining(timeout)
  end

  sig { void }
  def reset
    ref = case @ref_type
    when :branch
      "origin/#{@ref}"
    when :revision, :tag
      @ref
    end

    command! "git",
             args:  ["reset", "--hard", *ref, "--"],
             chdir: cached_location
  end

  sig { params(timeout: T.nilable(Time)).void }
  def update_submodules(timeout: nil)
    command! "git",
             args:    ["submodule", "foreach", "--recursive", "git submodule sync"],
             chdir:   cached_location,
             timeout: Utils::Timer.remaining(timeout)
    command! "git",
             args:    ["submodule", "update", "--init", "--recursive"],
             chdir:   cached_location,
             timeout: Utils::Timer.remaining(timeout)
    fix_absolute_submodule_gitdir_references!
  end

  # When checking out Git repositories with recursive submodules, some Git
  # versions create `.git` files with absolute instead of relative `gitdir:`
  # pointers. This works for the cached location, but breaks various Git
  # operations once the affected Git resource is staged, i.e. recursively
  # copied to a new location. (This bug was introduced in Git 2.7.0 and fixed
  # in 2.8.3. Clones created with affected version remain broken.)
  # See https://github.com/Homebrew/homebrew-core/pull/1520 for an example.
  sig { void }
  def fix_absolute_submodule_gitdir_references!
    submodule_dirs = command!("git",
                              args:  ["submodule", "--quiet", "foreach", "--recursive", "pwd"],
                              chdir: cached_location).stdout

    submodule_dirs.lines.map(&:chomp).each do |submodule_dir|
      work_dir = Pathname.new(submodule_dir)

      # Only check and fix if `.git` is a regular file, not a directory.
      dot_git = work_dir/".git"
      next unless dot_git.file?

      # This Ruby write runs in the parent, outside Git's sandbox.
      Utils::Path.ensure_child_of!(cached_location, dot_git,
                                   message: "Git submodule metadata escapes the download directory: #{dot_git}")

      git_dir = dot_git.read.chomp[/^gitdir: (.*)$/, 1]
      if git_dir.nil?
        onoe "Failed to parse '#{dot_git}'." if Homebrew::EnvConfig.developer?
        next
      end

      # Only attempt to fix absolute paths.
      next unless git_dir.start_with?("/")

      # Make the `gitdir:` reference relative to the working directory.
      relative_git_dir = Pathname.new(git_dir).relative_path_from(work_dir)
      dot_git.atomic_write("gitdir: #{relative_git_dir}\n")
    end
  end

  sig { void }
  def configure_sparse_checkout
    command! "git",
             args:  ["config", "core.sparseCheckout", "true"],
             chdir: cached_location
    command! "git",
             args:  ["config", "core.sparseCheckoutCone", "true"],
             chdir: cached_location

    (git_dir/"info").mkpath
    (git_dir/"info/sparse-checkout").atomic_write("#{@only_path}\n")
  end
end
