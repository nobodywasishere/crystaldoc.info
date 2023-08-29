module CrystalDoc::Git
  def self.valid_vcs_url?(repo_url : String) : Bool
    ls_remote(STDOUT, args: [repo_url])
    # Mercurial - hg identify
  end

  def self.ls_remote(output : Process::Stdio = Process::Redirect::Close, args : Array(String) = [] of String) : Bool
    Process.run("git", ["ls-remote", *args], output: output, env: {"GIT_TERMINAL_PROMPT" => "0"}).success?
  end

  def self.versions(repo_url : String, &)
    stdout = IO::Memory.new
    unless ls_remote(stdout, [repo_url])
      raise "git ls-remote failed"
    end
    tags_key = "refs/tags/"
    # stdio.each_line doesn't work for some reason, had to convert to string first
    stdout.to_s.each_line do |line|
      split_line = line.split('\t')
      hash = split_line[0]
      tag = split_line[1].lchop?(tags_key)
      unless tag.nil?
        yield hash, tag
      end
    end
  end

  def self.main_branch(repo_url : String) : String?
    stdout = IO::Memory.new
    unless ls_remote(stdout, ["--symref", repo_url, "HEAD"])
      raise "git ls-remote failed"
    end
    stdout.to_s.match(/ref: refs\/heads\/(.+)	HEAD/).try &.[1]
  end
end
