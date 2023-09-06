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
    CrystalDoc::VCS.versions(source_url) do |hash, tag|
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
      SELECT repo_version.commit_id, repo_version.nightly
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
        "released" => !version.nightly,
      }
    end

    if output.empty?
      return {"versions" => [] of String}.to_json
    end

    {"versions" => [output.first] + output[1..].reverse}.to_json
  end

  def self.find_repo(db : Queriable, user : String, proj : String) : Array(Repo)
    db.query_all(<<-SQL, user, proj, as: {Repo})
      SELECT DISTINCT service, username, project_name, user_distance, proj_distance
      FROM (
        SELECT repo.service, repo.username, repo.project_name, repo.id,
        (levenshtein_less_equal(repo.username, $1, 21, 1, 10, 10)) AS user_distance,
        (levenshtein_less_equal(repo.project_name, $2, 21, 1, 10, 10)) AS proj_distance
        FROM crystal_doc.repo
      ) AS repo
      INNER JOIN crystal_doc.repo_version
        ON repo_version.repo_id = repo.id
      WHERE repo_version.valid = true AND user_distance <= 20 AND proj_distance <= 20
      ORDER BY user_distance, proj_distance
      LIMIT 10;
    SQL
  end

  def self.random_repo(db : Queriable) : Repo
    db.query_one(<<-SQL, as: Repo)
      SELECT DISTINCT repo.service, repo.username, repo.project_name, RANDOM()
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
      SELECT DISTINCT repo.service, repo.username, repo.project_name, repo.id
      FROM crystal_doc.repo
      INNER JOIN crystal_doc.repo_version
        ON repo_version.repo_id = repo.id
      WHERE repo_version.valid = true
      ORDER BY repo.id DESC
      LIMIT $1;
    SQL
  end

  def self.repo_needs_updating(db : Queriable) : Array(Repo)
    db.query_all(<<-SQL, as: {Repo})
      SELECT service, username, project_name, abs(current_date - repo_status.last_checked::date) as date_diff
      FROM crystal_doc.repo
      INNER JOIN crystal_doc.repo_status
        ON repo_status.repo_id = repo.id
      WHERE abs(current_date - repo_status.last_checked::date) >= 1
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
      SELECT repo.service, repo.username, repo.project_name
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
    Log.info { "Updating repo #{repo_id} status with last commit #{last_commit}" }
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
end
