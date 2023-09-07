require "./crystaldoc"

Dir.mkdir_p "./logs"
log_file = File.new("./logs/searcher.log", "a+")

Log.setup(:info, Log::IOBackend.new(log_file))

REPO_DB = DB.open(ENV["POSTGRES_DB"])

class CrystalDoc::CLI::Searcher
  Log = ::Log.for("searcher")

  def initialize(@idx : Int32)
    Log.info { "Starting crystaldoc searcher" }
  end

  def search(db : Queriable)
    log = CrystalDoc::CLI::Searcher::Log.for("#{@idx}")

    db.transaction do |tx|
      conn = tx.connection

      # go through every repo
      log.info { "Searching for new versions..." }
      repos = CrystalDoc::Queries.repo_needs_updating(conn)

      if repos.empty?
        log.info { "No repos need updating." }
        sleep(50)
        break
      else
        log.info { "Refreshing repo #{repos.first.path}" }
        repo = repos.first
      end

      log.info { "Getting repo_id..." }
      repo_id = conn.query_one(<<-SQL, repo.service, repo.username, repo.project_name, as: Int32)
        SELECT repo.id
        FROM crystal_doc.repo
        WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3
      SQL

      log.info { "Getting source_url..." }
      source_url = conn.query_one(<<-SQL, repo_id, as: String)
        SELECT repo.source_url
        FROM crystal_doc.repo
        WHERE repo.id = $1
      SQL

      # check for new versions
      log.info { "Getting repo versions..." }
      CrystalDoc::Queries.refresh_repo_versions(conn, repo_id)

      log.info { "Checking current commit hash..." }
      current_commit_hash = CrystalDoc::VCS.main_commit_hash(source_url)

      old_commit_hash = conn.query_one(<<-SQL, repo_id, as: String)
        SELECT repo_status.last_commit
        FROM crystal_doc.repo_status
        WHERE repo_status.repo_id = $1
      SQL

      if old_commit_hash == current_commit_hash
        log.info { "Old commit hash matches current, no updated needed." }
        CrystalDoc::Queries.upsert_repo_status(conn, old_commit_hash, repo_id)
        break
      end

      nightly_id = CrystalDoc::Queries.repo_nightly_version_id(conn,
        repo.service, repo.username, repo.project_name
      )
      CrystalDoc::Queries.insert_doc_job(conn, nightly_id, CrystalDoc::DocJob::LATEST_PRIORITY)
      CrystalDoc::Queries.upsert_repo_status(conn, current_commit_hash, repo_id)

      log.info { "Refreshing repo versions..." }
      CrystalDoc::Queries.refresh_repo_versions(conn, repo_id)
    rescue ex
      log.error { "Searcher Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}" }
      tx.try &.rollback if ex.is_a? PG::Error
    end
  end
end

# Version checker
(1..ENV["CRYSTAL_WORKERS"]?.try &.to_i || 4).each do |idx|
  spawn do
    searcher = CrystalDoc::CLI::Searcher.new(idx)

    loop do
      searcher.search(REPO_DB)
      sleep(10)
    end
  end
end

sleep
