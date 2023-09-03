require "./crystaldoc"

REPO_DB = DB.open(ENV["POSTGRES_DB"])

# Version checker
(1..ENV["CRYSTAL_WORKERS"]?.try &.to_i || 4).each do
  spawn do
    loop do
      REPO_DB.transaction do |tx|
        conn = tx.connection

        # go through every repo
        puts "Searching for new versions..."
        repos = CrystalDoc::Queries.repo_needs_updating(conn)

        if repos.empty?
          puts "No repos need updating."
          break
        else
          puts "Refreshing repo #{repos.first["path"]}"
          repo = repos.first
        end

        puts "Getting repo_id..."
        repo_id = conn.query_one(<<-SQL, repo["service"], repo["username"], repo["project_name"], as: Int32)
          SELECT repo.id
          FROM crystal_doc.repo
          WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3
        SQL

        puts "Getting source_url..."
        source_url = conn.query_one(<<-SQL, repo_id, as: String)
          SELECT repo.source_url
          FROM crystal_doc.repo
          WHERE repo.id = $1
        SQL

        # check for new versions
        puts "Getting repo versions..."
        CrystalDoc::Queries.refresh_repo_versions(conn, repo_id)

        puts "Checking current commit hash..."
        current_commit_hash = CrystalDoc::VCS.main_commit_hash(source_url)

        old_commit_hash = conn.query_one(<<-SQL, repo_id, as: String)
          SELECT repo_status.last_commit
          FROM crystal_doc.repo_status
          WHERE repo_status.repo_id = $1
        SQL

        if old_commit_hash == current_commit_hash
          puts "Old commit hash matches current, no updated needed."
          CrystalDoc::Queries.upsert_repo_status(conn, old_commit_hash, repo_id)
          break
        end

        nightly_id = CrystalDoc::Queries.repo_nightly_version_id(conn,
          repo["service"], repo["username"], repo["project_name"]
        )
        CrystalDoc::Queries.insert_doc_job(conn, nightly_id, CrystalDoc::DocJob::LATEST_PRIORITY)
        CrystalDoc::Queries.upsert_repo_status(conn, current_commit_hash, repo_id)

        puts "Refreshing repo versions..."
        CrystalDoc::Queries.refresh_repo_versions(conn, repo_id)
      rescue ex
        puts "Searcher Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}"
        tx.try &.rollback if ex.is_a? PG::Error
      end

      sleep(15)
    end
  end
end

sleep
