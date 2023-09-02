require "./crystaldoc"

# Version checker
(1..ENV["CRYSTAL_WORKERS"]?.try &.to_i || 4).each do
  spawn do
    loop do
      DB.open(ENV["POSTGRES_DB"]) do |db|
        db.transaction do |tx|
          puts "Searching for new versions..."

          conn = tx.connection

          # go through every repo
          repos = CrystalDoc::Queries.repo_needs_updating(conn)

          if repos.empty?
            puts "No repos need updating."
            sleep(10)
            next
          else
            repo = repos.first
          end

          repo_id = db.query_one(<<-SQL, repo["service"], repo["username"], repo["project_name"], as: Int32)
            SELECT repo.id
            FROM crystal_doc.repo
            WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3
          SQL

          source_url = db.query_one(<<-SQL, repo_id, as: String)
            SELECT repo.source_url
            FROM crystal_doc.repo
            WHERE repo.id = $1
          SQL

          # check for new versions
          CrystalDoc::Queries.refresh_repo_versions(conn, repo_id)

          current_commit_hash = CrystalDoc::VCS.main_commit_hash(source_url)

          old_commit_hash = conn.query_one(<<-SQL, repo_id, as: String)
            SELECT repo_status.last_commit
            FROM crystal_doc.repo_status
            WHERE repo_status.repo_id = $1
          SQL

          if old_commit_hash == current_commit_hash
            CrystalDoc::Queries.upsert_repo_status(conn, current_commit_hash, repo_id)
            next
          end

          CrystalDoc::Queries.refresh_repo_versions(conn, repo_id)
        end
      rescue ex
        puts "Searcher Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}"
        sleep 10
      end
    end
  end
end

sleep
