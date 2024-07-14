require "http/status"

class CrystalDoc::VCS
  Log = ::Log.for(self)

  getter :source_url

  def initialize(@source_url : String)
    raise "Invalid URL" unless valid_url?
  end

  def parse(db : Queriable) : String
    # parse/validate url
    repo = parse_url
    repo_id = nil

    # db transaction
    db.transaction do |tx|
      conn = tx.connection

      # db query add repo to repo table
      repo_id = conn.scalar(<<-SQL, repo["service"], repo["username"], repo["project_name"], source_url).as(Int32)
        INSERT INTO crystal_doc.repo (service, username, project_name, source_url)
        VALUES ($1, $2, $3, $4)
        RETURNING id
      SQL

      # get nightly version
      if (nightly_ver = main_branch).nil? || (nightly_hash = main_commit_hash).nil?
        raise "Failed to find main branch"
      end

      # add nightly version to versions table
      nightly_id = CrystalDoc::Queries.insert_repo_version(conn, repo_id, nightly_ver, true)

      CrystalDoc::Queries.update_latest_repo_version(conn, repo_id, nightly_id)
      CrystalDoc::Queries.insert_doc_job(conn, nightly_id, CrystalDoc::DocJob::LATEST_PRIORITY)

      CrystalDoc::Queries.upsert_repo_status(conn, nightly_hash, repo_id)
      CrystalDoc::Queries.refresh_repo_versions(conn, repo_id)
    end

    if repo_id
      data = Ext.get_data_for(repo["service"], repo["username"], repo["project_name"])
      CrystalDoc::Queries.update_repo_data(db, repo_id, data) if data
    end

    "Successfully added repo"
  rescue ex
    Log.error { "VCS Exception: #{ex}:\n  #{ex.backtrace.join("\n  ")}" }
    "Failed to add repo"
  end

  private def valid_url? : Bool
    Log.info { "Verifying URL status code successful" }

    stdout = IO::Memory.new
    response = Process.run("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", source_url], output: stdout)

    Log.info { "Source URL '#{source_url}' HTTP code: #{stdout.to_s}" }
    return false unless HTTP::Status.new(stdout.to_s.to_i).success? || HTTP::Status.new(stdout.to_s.to_i).redirection?

    Log.info { "Verifying git url successful" }

    return false unless Process.run("git", ["ls-remote", source_url], env: {"GIT_TERMINAL_PROMPT" => "0"}).success?

    true
  end

  private def parse_url : Hash(String, String)
    uri = URI.parse(source_url).normalize
    service = URI.parse(source_url).host.try &.gsub(/\.com$/, "").gsub(/\./, "-")

    path_fragments = uri.path.split('/')[1..]
    raise "Invalid url" if path_fragments.size != 2 || service.nil?

    username = path_fragments[0]
    project_name = path_fragments[1]

    raise "Invalid username" unless /^~?[\w\.\-_]+$/.match(username)
    raise "Invalid project name" unless /^[\w\.\-_]+$/.match(project_name)

    {
      "service"      => service,
      "username"     => username,
      "project_name" => project_name,
    }
  end

  def main_branch : String?
    raise "Invalid URL" unless valid_url?

    stdout = IO::Memory.new
    unless Process.run(
             "git",
             [
               "ls-remote",
               "--symref",
               source_url,
               "HEAD",
             ],
             output: stdout,
             env: {"GIT_TERMINAL_PROMPT" => "0"}
           ).success?
      raise "git ls-remote failed (#{source_url}): #{stdout}"
    end
    stdout.to_s.match(/ref: refs\/heads\/(.+)	HEAD/).try &.[1]
  end

  def main_commit_hash : String?
    raise "Invalid URL" unless valid_url?

    stdout = IO::Memory.new
    unless Process.run(
             "git",
             [
               "ls-remote",
               source_url,
               "HEAD",
             ],
             output: stdout,
             env: {"GIT_TERMINAL_PROMPT" => "0"}
           ).success?
      raise "git ls-remote failed (#{source_url}): #{stdout}"
    end
    stdout.to_s.match(/^(.+)\s+HEAD/).try &.[1]
  end

  def self.versions(source_url, &)
    self.new(source_url) # Check if URL valid

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    unless Process.run(
             "git",
             [
               "-c", "versionsort.suffix=-",
               "ls-remote",
               "--refs",
               "--tags",
               "--sort", "v:refname",
               source_url,
             ],
             output: stdout,
             error: stderr,
             env: {"GIT_TERMINAL_PROMPT" => "0"}
           ).success?
      raise "git ls-remote failed (#{source_url}): #{stdout} #{stderr}"
    end

    # stdio.each_line doesn't work for some reason, had to convert to string first
    stdout.to_s.each_line do |line|
      split_line = line.split('\t')

      hash = split_line[0]
      tag = split_line[1].lchop("refs/tags/")

      unless tag.nil?
        yield hash, tag
      end
    end
  end

  def self.main_commit_hash(source_url : String) : String
    vcs = CrystalDoc::VCS.new(source_url)
    vcs.main_commit_hash || raise "No main commit hash for #{source_url}"
  end
end
