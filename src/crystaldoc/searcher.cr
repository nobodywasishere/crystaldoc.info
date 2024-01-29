class CrystalDoc::CLI::Searcher
  Log = ::Log.for("searcher")

  getter idx : Int32

  def initialize(@idx)
    Log.info { "#{idx}: Starting crystaldoc searcher" }
  end

  def search_for_jobs(db : Queriable)
    loop do
      db.transaction do |tx|
        conn = tx.connection

        # go through every repo
        Log.info { "#{idx}: Searching for new versions..." }
        repos = CrystalDoc::Queries.repo_needs_updating(conn)

        if repos.empty?
          Log.info { "#{idx}: No repos need updating." }
          sleep(50)
          break
        end

        Log.info { "#{idx}: Refreshing repo #{repos.first.path}" }
        repo = repos.first

        update_repo(conn, repo)
      rescue ex
        Log.error { "#{idx}: Searcher Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}" }
        tx.try &.rollback # if ex.is_a? PG::Error

        if repo
          Log.info { "#{idx}: Marking repo as failed" }
          repo_id = CrystalDoc::Queries.get_repo_id(db, repo.source_url)
          CrystalDoc::Queries.upsert_repo_status(db, "FAILURE", repo_id)
        end
      end

      sleep(10)
    end
  end

  def update_repo(db : Queriable, repo : Repo)
    Log.info { "#{idx}: Getting repo_id..." }
    repo_id = CrystalDoc::Queries.get_repo_id(db, repo.source_url)

    # check for new versions
    Log.info { "#{idx}: Getting repo versions..." }
    CrystalDoc::Queries.refresh_repo_versions(db, repo_id)

    Log.info { "#{idx}: Checking current commit hash..." }
    current_commit_hash = CrystalDoc::VCS.main_commit_hash(repo.source_url)

    old_commit_hash = db.query_one(<<-SQL, repo_id, as: String)
      SELECT repo_status.last_commit
      FROM crystal_doc.repo_status
      WHERE repo_status.repo_id = $1
    SQL

    if old_commit_hash == current_commit_hash
      Log.info { "#{idx}: Old commit hash matches current, no updated needed." }
      CrystalDoc::Queries.upsert_repo_status(db, old_commit_hash, repo_id)
      return
    end

    nightly_id = CrystalDoc::Queries.repo_nightly_version_id(db,
      repo.service, repo.username, repo.project_name
    )
    CrystalDoc::Queries.insert_doc_job(db, nightly_id, CrystalDoc::DocJob::LATEST_PRIORITY)
    CrystalDoc::Queries.upsert_repo_status(db, current_commit_hash, repo_id)

    Log.info { "#{idx}: Refreshing repo versions..." }
    CrystalDoc::Queries.refresh_repo_versions(db, repo_id)
  end

  def update_repo_stats(db : Queriable, repo : Repo)
    data = Ext.get_data_for(repo)
    CrystalDoc::Queries.update_repo_data(db, data) if data
  end
end
