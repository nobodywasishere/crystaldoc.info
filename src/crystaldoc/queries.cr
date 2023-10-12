module CrystalDoc::Queries
  Log = ::Log.for(self)

  # Returns the current latest version as a string for a service/username/project_name combination
  def self.latest_version(db : Queriable, service : String, username : String, project_name : String) : String
    db.query_all(<<-SQL, service, username, project_name, as: {String}).first
      SELECT repo_version.commit_id
      FROM crystal_doc.repo_version
      INNER JOIN crystal_doc.repo_status
        ON repo_version.repo_id = repo_status.repo_id
      INNER JOIN crystal_doc.repo
        ON repo.id = repo_version.repo_id
      WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3 AND repo_version.valid = true
      ORDER BY repo_version.id DESC
      LIMIT 1;
    SQL
  end

  def self.update_latest_repo_version(db : Queriable, repo_id : Int32, latest_version_id : Int32)
    db.exec(<<-SQL, repo_id, latest_version_id)
      INSERT INTO crystal_doc.repo_latest_version (repo_id, latest_version)
      VALUES (
        (
          SELECT repo.id
          FROM crystal_doc.repo
          WHERE id = $1
        ),
        $2
      )
      ON CONFLICT(repo_id) DO UPDATE SET latest_version = EXCLUDED.latest_version
    SQL
  end

  def self.current_repo_versions(db : Queriable, repo_id) : Array(String)
    db.query_all(<<-SQL, repo_id, as: {String})
      SELECT repo_version.commit_id
      FROM crystal_doc.repo_version
      WHERE repo_version.repo_id = $1
    SQL
  end

  def self.insert_repo_version(db : Queriable, repo_id : Int32, tag : String, nightly : Bool) : Int32
    db.scalar(<<-SQL, repo_id, tag, nightly).as(Int32)
      INSERT INTO crystal_doc.repo_version (repo_id, commit_id, nightly)
      VALUES ($1, $2, $3)
      ON CONFLICT (repo_id, commit_id) DO UPDATE
      SET repo_id = crystal_doc.repo_version.repo_id
      RETURNING id
    SQL
  end

  def self.refresh_repo_versions(db : Queriable, repo_id : Int32)
    source_url = db.query_one(<<-SQL, repo_id, as: String)
      SELECT repo.source_url
      FROM crystal_doc.repo
      WHERE repo.id = $1
    SQL

    last_version_id = nil
    new_version_ids = [] of Int32
    current_version_tags = current_repo_versions(db, repo_id)
    CrystalDoc::VCS.versions(source_url) do |_, tag|
      next if tag.nil? || /[^\w\.\-_]/.match(tag)
      next if current_version_tags.includes? tag

      # add versions to versions table
      Log.info { "New version for repo #{repo_id}: #{tag}" }
      id = insert_repo_version(db, repo_id, tag, false)

      last_version_id = id
      new_version_ids << id
    end

    new_version_ids.each_with_index do |version, index|
      if index == 0
        priority = CrystalDoc::DocJob::LATEST_PRIORITY
      else
        priority = (new_version_ids.size - 1 - index) * CrystalDoc::DocJob::HISTORICAL_PRIORITY
      end

      CrystalDoc::Queries.insert_doc_job(db, version, priority)
    end

    unless last_version_id.nil?
      self.update_latest_repo_version(db, repo_id, last_version_id)
    end
  end

  def self.mark_version_valid(db : Queriable, commit : String, service : String, username : String, project_name : String)
    db.exec(<<-SQL, commit, service, username, project_name)
      UPDATE crystal_doc.repo_version
      SET valid = true
      FROM crystal_doc.repo
      WHERE repo.id = repo_version.repo_id
        AND repo_version.commit_id = $1
        AND repo.service = $2
        AND repo.username = $3
        AND repo.project_name = $4
    SQL
  end

  def self.mark_version_invalid(db : Queriable, commit : String, service : String, username : String, project_name : String)
    db.exec(<<-SQL, commit, service, username, project_name)
      UPDATE crystal_doc.repo_version
      SET valid = false
      FROM crystal_doc.repo
      WHERE repo.id = repo_version.repo_id
        AND repo_version.commit_id = $1
        AND repo.service = $2
        AND repo.username = $3
        AND repo.project_name = $4
    SQL
  end

  def self.repo_nightly_version_id(db : Queriable, service : String, username : String, project_name : String) : Int32
    db.query_one(<<-SQL, service, username, project_name, as: Int32)
      SELECT repo_version.id
      FROM crystal_doc.repo_version
      INNER JOIN crystal_doc.repo
        ON repo.id = repo_version.repo_id
      WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3 AND repo_version.nightly = true
      LIMIT 1;
    SQL
  end

  def self.versions_json(db : Queriable, service : String, username : String, project_name : String) : String
    versions = db.query_all(<<-SQL, service, username, project_name, as: {RepoVersion})
      SELECT repo_version.commit_id, repo_version.nightly, repo_version.valid
      FROM crystal_doc.repo_version
      INNER JOIN crystal_doc.repo
        ON repo.id = repo_version.repo_id
      WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3 AND repo_version.valid = true
      ORDER BY repo_version.id ASC
    SQL

    output = [] of Hash(String, String | Bool)

    versions.each do |version|
      output << {
        "name"     => version.commit_id.to_s,
        "url"      => "/#{service}/#{username}/#{project_name}/#{version.commit_id}/",
        "released" => !version.nightly?,
      }
    end

    if output.empty?
      return {"versions" => [] of String}.to_json
    end

    {"versions" => output.select { |v| !v["released"] } + output.select { |v| v["released"] }.reverse!}.to_json
  end

  def self.find_repo(db : Queriable, user : String, proj : String, distinct : Bool = false) : Array(Repo)
    db.query_all(<<-SQL, user, proj, as: {Repo})
      SELECT DISTINCT service, username, project_name, source_url, build_type
      FROM crystal_doc.repo
      INNER JOIN crystal_doc.repo_version
        ON repo_version.repo_id = repo.id
      WHERE repo_version.valid = true AND (position(LOWER($1) in LOWER(username)) > 0 #{distinct ? "AND" : "OR"} position(LOWER($2) in LOWER(project_name)) > 0)
      LIMIT 10;
    SQL
  end

  def self.random_repo(db : Queriable) : Repo
    db.query_one(<<-SQL, as: Repo)
      SELECT DISTINCT repo.service, repo.username, repo.project_name, repo.source_url, repo.build_type, RANDOM()
      FROM crystal_doc.repo
      INNER JOIN crystal_doc.repo_version
        ON repo_version.repo_id = repo.id
      WHERE repo_version.valid = true
      ORDER BY RANDOM()
      LIMIT 1;
    SQL
  end

  def self.recently_added_repos(db : Queriable, count : Int32 = 10) : Array(Repo)
    db.query_all(<<-SQL, count, as: {Repo})
      SELECT DISTINCT repo.service, repo.username, repo.project_name, repo.source_url, repo.build_type, repo.id
      FROM crystal_doc.repo
      INNER JOIN crystal_doc.repo_version
        ON repo_version.repo_id = repo.id
      WHERE repo_version.valid = true
      ORDER BY repo.id DESC
      LIMIT $1;
    SQL
  end

  def self.recently_updated_repos(db : Queriable, count : Int32 = 10) : Array(Repo)
    db.query_all(<<-SQL, count, as: {Repo})
      SELECT DISTINCT repo.service, repo.username, repo.project_name, repo.source_url, repo.build_type, MAX(repo_version.id) as repo_version_id
      FROM crystal_doc.repo
      INNER JOIN crystal_doc.repo_version
        ON repo_version.repo_id = repo.id
      WHERE repo_version.valid = true
      GROUP BY repo.service, repo.username, repo.project_name, repo.source_url, repo.build_type
      ORDER BY repo_version_id DESC
      LIMIT $1;
    SQL
  end

  def self.repo_needs_updating(db : Queriable) : Array(Repo)
    db.query_all(<<-SQL, as: {Repo})
      SELECT service, username, project_name, source_url, build_type, (NOW() - repo_status.last_checked) as date_diff
      FROM crystal_doc.repo
      INNER JOIN crystal_doc.repo_status
        ON repo_status.repo_id = repo.id
      WHERE (NOW() - repo_status.last_checked) >= interval '6 hours'
      FOR UPDATE SKIP LOCKED
      LIMIT 1;
    SQL
  end

  def self.repo_exists(db : Queriable, service : String, username : String, project_name : String) : Bool
    db.query_one(<<-SQL, service, username, project_name, as: Bool)
      SELECT EXISTS (
        SELECT 1
        FROM crystal_doc.repo
        WHERE service = $1 AND username = $2 AND project_name = $3
      )
    SQL
  end

  def self.repo_exists_and_valid(db : Queriable, service : String, username : String, project_name : String) : Bool
    db.query_one(<<-SQL, service, username, project_name, as: Bool)
      SELECT EXISTS (
        SELECT 1
        FROM crystal_doc.repo
        INNER JOIN crystal_doc.repo_version
          ON repo_version.repo_id = repo.id
        WHERE service = $1 AND username = $2 AND project_name = $3 AND repo_version.valid = true
      )
    SQL
  end

  def self.repo_exists(db : Queriable, source_url : String) : Bool
    db.query_one(<<-SQL, source_url, as: Bool)
      SELECT EXISTS (
        SELECT 1
        FROM crystal_doc.repo
        WHERE source_url = $1
      )
    SQL
  end

  def self.repo_from_source(db : Queriable, source_url : String) : Array(Repo)
    db.query_all(<<-SQL, source_url, as: {Repo})
      SELECT repo.service, repo.username, repo.project_name, repo.source_url, repo.build_type
      FROM crystal_doc.repo
      WHERE repo.source_url = $1
    SQL
  end

  def self.repo_version_exists(db : Queriable, service : String, username : String, project_name : String, version : String) : Bool
    db.query_one(<<-SQL, service, username, project_name, version, as: Bool)
      SELECT EXISTS (
        SELECT 1
        FROM crystal_doc.repo_version
        INNER JOIN crystal_doc.repo
          ON repo.id = repo_version.repo_id
        WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3 AND repo_version.commit_id = $4
      )
    SQL
  end

  def self.upsert_repo_status(db : Queriable, last_commit : String, repo_id : Int32)
    # Log.info { "Updating repo #{repo_id} status with last commit #{last_commit}" }
    db.exec(<<-SQL, last_commit, repo_id)
      INSERT INTO crystal_doc.repo_status (repo_id, last_commit, last_checked)
      VALUES (
        (
          SELECT repo.id
          FROM crystal_doc.repo
          WHERE repo.id = $2
        ),
        $1,
        now()
      )
      ON CONFLICT(repo_id) DO UPDATE SET (last_commit, last_checked) = (EXCLUDED.last_commit, EXCLUDED.last_checked)
    SQL
  end

  def self.insert_doc_job(db : Queriable, version_id : Int32, priority : Int32)
    Log.info { "Inserting doc job for #{version_id}" }
    db.exec(<<-SQL, version_id, priority)
      INSERT INTO crystal_doc.doc_job (version_id, priority)
      VALUES ($1, $2)
      ON CONFLICT(version_id) DO NOTHING
      RETURNING id
    SQL
  end

  def self.repo_count(db : Queriable)
    db.scalar(<<-SQL).as(Int64)
      SELECT COUNT(repo.id)
      FROM crystal_doc.repo;
    SQL
  end

  def self.repo_version_valid_count(db : Queriable)
    db.scalar(<<-SQL).as(Int64)
      SELECT COUNT(repo_version.id)
      FROM crystal_doc.repo_version
      WHERE repo_version.valid = true;
    SQL
  end

  def self.repo_version_invalid_count(db : Queriable)
    db.scalar(<<-SQL).as(Int64)
      SELECT COUNT(repo_version.id)
      FROM crystal_doc.repo_version
      WHERE repo_version.valid = false
      AND repo_version.id NOT IN (SELECT doc_job.version_id FROM crystal_doc.doc_job);
    SQL
  end

  def self.featured_repos(db : Queriable, count : Int32 = 10) : Array(Repo)
    db.query_all(<<-SQL, count, as: {Repo})
      SELECT repo.service, repo.username, repo.project_name, repo.source_url, repo.build_type
      FROM crystal_doc.repo
      INNER JOIN crystal_doc.featured_repo
        ON featured_repo.repo_id = repo.id
      ORDER BY repo.id ASC
      LIMIT $1;
    SQL
  end

  def self.add_featured_repo(db : Queriable, repo_id : Int32)
    db.exec <<-SQL, repo_id
      INSERT INTO crystal_doc.featured_repo (repo_id)
      VALUES ($1)
      ON CONFLICT (repo_id) DO NOTHING;
    SQL
  end

  def self.remove_featured_repo(db : Queriable, repo_id : Int32)
    db.exec <<-SQL, repo_id
      DELETE FROM crystal_doc.featured_repo
      WHERE featured_repo.repo_id = $1;
    SQL
  end

  def self.get_repo_id(db : Queriable, source_url : String)
    db.query_one(<<-SQL, source_url, as: Int32)
      SELECT repo.id
      FROM crystal_doc.repo
      WHERE repo.source_url = $1
    SQL
  end
end
