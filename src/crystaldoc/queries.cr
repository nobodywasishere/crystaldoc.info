module CrystalDoc::Queries
  # Returns the current latest version as a string for a service/username/project_name combination
  def self.latest_version(db : Queriable, service : String, username : String, project_name : String) : String?
    rs = db.query(<<-SQL, service, username, project_name)
      SELECT repo_version.commit_id
      FROM crystal_doc.repo_version
      INNER JOIN crystal_doc.repo_latest_version
        ON repo_version.id = repo_latest_version.latest_version
      INNER JOIN crystal_doc.repo
        ON repo.id = repo_latest_version.repo_id
      WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3
    SQL

    rs.each do
      return rs.read(String)
    end

    nil
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

  def self.refresh_repo_versions(db : Queriable, repo_id : Int32)
    source_url = db.query_one(<<-SQL, repo_id, as: String)
      SELECT repo.source_url
      FROM crystal_doc.repo
      WHERE repo.id = $1
    SQL

    last_version_id = nil
    CrystalDoc::VCS.versions(source_url) do |hash, tag|
      next if tag.nil? || /[^\w\.\-_]/.match(tag)

      # add versions to versions table
      rs = db.query(<<-SQL, repo_id, tag, false)
        INSERT INTO crystal_doc.repo_version (repo_id, commit_id, nightly)
        VALUES ($1, $2, $3)
        ON CONFLICT (repo_id, commit_id) DO NOTHING
        RETURNING id;
      SQL

      rs.each do
        last_version_id = rs.read(Int32)
      end
    end

    unless last_version_id.nil?
      self.update_latest_repo_version(db, repo_id, last_version_id)
    end
  end

  def self.versions_json(db : Queriable, service : String, username : String, project_name : String) : String
    versions_rs = db.query(<<-SQL, service, username, project_name)
      SELECT repo_version.commit_id, repo_version.nightly
      FROM crystal_doc.repo_version
      INNER JOIN crystal_doc.repo
        ON repo.id = repo_version.repo_id
      WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3
      ORDER BY repo_version.id ASC
    SQL

    versions = [] of Hash(String, String | Bool)

    versions_rs.each do
      commit_id = versions_rs.read(String)
      nightly = versions_rs.read(Bool)

      versions << {
        "name"     => commit_id,
        "url"      => "/#{service}/#{username}/#{project_name}/#{commit_id}/",
        "released" => !nightly,
      }
    end

    {"versions" => [versions.first] + versions[1..].reverse}.to_json
  end

  def self.find_repo(db : Queriable, query : String) : Array(Hash(String, String))
    rs_to_repo(db.query(<<-SQL, query))
      SELECT repo.service, repo.username, repo.project_name
      FROM crystal_doc.repo
      WHERE levenshtein(repo.username, $1) <= 10 OR levenshtein(repo.project_name, $1) <= 10
      ORDER BY LEAST(levenshtein(repo.username, $1), levenshtein(repo.project_name, $1))
      LIMIT 10;
    SQL
  end

  def self.recently_added_repos(db : Queriable)
    rs_to_repo(db.query(<<-SQL))
      SELECT repo.service, repo.username, repo.project_name
      FROM crystal_doc.repo
      ORDER BY id DESC
      LIMIT 10;
    SQL
  end

  def self.most_popular_repos(db : Queriable)
    rs_to_repo(db.query(<<-SQL))
      SELECT repo.service, repo.username, repo.project_name
      FROM crystal_doc.repo
      INNER JOIN crystal_doc.repo_statistics
        ON crystal_doc.repo.id = crystal_doc.repo_statistics.repo_id
      ORDER BY crystal_doc.repo_statistics.count DESC
      LIMIT 10;
    SQL
  end

  def self.rs_to_repo(rs : PG::ResultSet) : Array(Hash(String, String))
    repos = [] of Hash(String, String)

    rs.each do
      repos << {
        "service"      => service = rs.read(String),
        "username"     => username = rs.read(String),
        "project_name" => project_name = rs.read(String),
        "path"         => "/#{service}/#{username}/#{project_name}",
      }
    end

    repos
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

  def self.repo_version_exists(db : Queriable, repo_id : Int32, version : String) : Bool
    db.query_one(<<-SQL, repo_id, version, as: Bool)
      SELECT EXISTS (
        SELECT 1
        FROM crystal_doc.repo_version
        INNER JOIN crystal_doc.repo
          ON repo.id = repo_version.repo_id
        WHERE repo.id = $1 AND repo_version.commit_id = $2
      )
    SQL
  end

  def self.increment_repo_stats(db : Queriable, service : String, username : String, project_name : String)
    db.exec(<<-SQL, service, username, project_name)
      INSERT INTO crystal_doc.repo_statistics(repo_id, count)
      VALUES (
        (
          SELECT repo.id
          FROM crystal_doc.repo
          WHERE service = $1 AND username = $2 AND project_name = $3
        ),
        1
      )
      ON CONFLICT (repo_id) DO
      UPDATE SET count = crystal_doc.repo_statistics.count + 1;
    SQL
  end

  def self.upsert_repo_status(db : Queriable, repo_id : Int32)
    db.exec(<<-SQL, repo_id)
      INSERT INTO crystal_doc.repo_status (repo_id, last_commit, last_checked)
      VALUES (
        (
          SELECT repo.id
          FROM crystal_doc.repo
          WHERE repo.id = $1
        ),
        'UNUSED',
        now()
      )
      ON CONFLICT(repo_id) DO UPDATE SET last_checked = EXCLUDED.last_checked
    SQL
  end
end
