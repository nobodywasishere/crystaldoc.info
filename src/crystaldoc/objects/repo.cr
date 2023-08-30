class CrystalDoc::Repo
  include DB::Serializable

  getter id : Int32
  getter service : String
  getter username : String
  getter project_name : String
  getter source_url : String

  def initialize(@id : Int32, @service : String, @username : String, @project_name : String, @source_url : String)
  end

  def self.uri_to_service(uri : URI) : String
    if (host = uri.host).nil?
      raise "No host: #{uri}"
    end

    host.gsub(/\.com$/, "").gsub(/\./, "-")
  end

  def self.from_kemal_env(db : Queriable, env) : Repo?
    db.query_one(
      "SELECT * FROM crystal_doc.repo WHERE service = $1 AND username = $2 AND project_name = $3",
      env.params.url["serv"], env.params.url["user"], env.params.url["proj"],
      as: Repo
    )
  end

  def self.from_request(db : Queriable, request : HTTP::Request) : Repo?
    if (split_path = request.path.split("/")).size < 4
      return nil
    end

    db.query_one(<<-SQL, split_path[1], split_path[2], split_path[3], as: Repo)
      SELECT *
      FROM crystal_doc.repo
      WHERE service = $1 AND username = $2 AND project_name = $3
    SQL
  end

  def self.exists(db : Queriable, repo_url : String) : Bool
    db.scalar(
      "SELECT EXISTS(SELECT 1 FROM crystal_doc.repo WHERE repo.source_url = $1)",
      repo_url
    ).as(Bool)
  end

  def self.from_url(db : Queriable, source_url : String) : Repo?
    uri = URI.parse(source_url).normalize

    path_fragments = uri.path.split('/')[1..]
    raise "Invalid url component: #{uri.path}" if path_fragments.size != 2

    service = self.uri_to_service(uri)
    username = path_fragments[0]
    project_name = path_fragments[1]

    db.query_one(
      "SELECT * FROM crystal_doc.repo WHERE service = $1 AND username = $2 AND project_name = $3",
      service, username, project_name,
      as: Repo
    )
  end

  def self.create(db : Queriable, source_url : String) : Repo
    uri = URI.parse(source_url).normalize

    path_fragments = uri.path.split('/')[1..]
    raise "Invalid url component: #{uri.path}" if path_fragments.size != 2

    service = self.uri_to_service(uri)
    username = path_fragments[0]
    project_name = path_fragments[1]

    self.create(db, service, username, project_name, source_url)
  end

  def self.create(db : Queriable, service : String, username : String, project_name : String, source_url : String) : Repo
    id = db.scalar(<<-SQL, service, username, project_name, source_url).as(Int32)
      INSERT INTO crystal_doc.repo (service, username, project_name, source_url)
      VALUES ($1, $2, $3, $4)
      RETURNING id
    SQL
    Repo.new(id, service, username, project_name, source_url)
  end

  def self.add_new_repo(db : CrystalDoc::Queriable, repo_url : String)
    repo_info = CrystalDoc::Repo.parse_url(repo_url)

    db.transaction do |tx|
      conn = tx.connection
      # Insert repo into database
      repo = CrystalDoc::Repo.create(conn, repo_info[:service], repo_info[:username], repo_info[:project_name], repo_url)

      nightly_version = CrystalDoc::Git.main_branch(repo_url)
      nightly_version_id = nil
      if nightly_version
        nightly_version_id = CrystalDoc::RepoVersion.create(conn, repo.id, nightly_version, nightly: true)
      end

      # Identify repo versions, and add to database
      versions = Array({id: Int32, normalized_form: SemanticVersion}).new
      CrystalDoc::Git.versions(repo_url) do |_, tag|
        normalized_version = SemanticVersion.parse(tag.lchop('v'))

        # Don't record version until we've tried to parse the version
        version_id = CrystalDoc::RepoVersion.create(conn, repo.id, tag)
        versions.push({id: version_id, normalized_form: normalized_version})
      rescue ArgumentError
        puts "Unknown version format \"#{tag}\" from repo \"#{repo_url}\""
      end

      versions = versions.sort_by { |version| version[:normalized_form] }

      # Add doc generation jobs to the database queue, prioritized newest to oldest
      versions.each_with_index do |version, index|
        priority = index == versions.size - 1 ? CrystalDoc::DocJob::LATEST_PRIORITY : (versions.size - 1 - index) * CrystalDoc::DocJob::HISTORICAL_PRIORITY
        CrystalDoc::DocJob.create(conn, version[:id], priority)
      end

      # Record latest repo version
      if versions.size > 0
        CrystalDoc::Repo.upsert_latest_version(conn, repo.id, versions[-1][:id])
      elsif nightly_version && nightly_version_id
        CrystalDoc::Repo.upsert_latest_version(conn, repo.id, nightly_version_id)
      end

      # Update the repo status (records the last time the repo was processed)
      CrystalDoc::Repo.upsert_repo_status(conn, repo.id)
    end
  end

  def self.refresh_versions(db : CrystalDoc::Queriable, repo_url : String)
    repo = CrystalDoc::Repo.from_url(db, repo_url)

    if repo.nil?
      raise "No such repo for #{repo_url}"
    end

    db.transaction do |tx|
      conn = tx.connection

      # Identify repo versions, and add to database
      current_versions = repo.versions(conn)

      if nightly_version = CrystalDoc::Git.main_branch(repo_url)
        if current_versions.none? { |cv| cv.commit_id == nightly_version }
          CrystalDoc::RepoVersion.create(conn, repo.id, nightly_version, nightly: true)
        end
      end

      new_versions = Array({id: Int32, normalized_form: SemanticVersion}).new
      CrystalDoc::Git.versions(repo_url) do |_, tag|
        if current_versions.any? { |cv| cv.commit_id == tag }
          puts "#{repo.username}/#{repo.project_name}: Version exists already #{tag}"
          next
        end

        normalized_version = SemanticVersion.parse(tag.lchop('v'))

        # Don't record version until we've tried to parse the version
        version_id = CrystalDoc::RepoVersion.create(conn, repo.id, tag)
        new_versions.push({id: version_id, normalized_form: normalized_version})
      rescue ArgumentError
        puts "Unknown version format \"#{tag}\" from repo \"#{repo_url}\""
      end
    end
  end

  def self.parse_url(repo_url : String) : {service: String, username: String, project_name: String}
    uri = URI.parse(repo_url).normalize
    service = uri_to_service(uri)

    path_fragments = uri.path.split('/')[1..]
    raise "Invalid url component: #{uri.path}" if path_fragments.size != 2

    username = path_fragments[0]
    project_name = path_fragments[1]

    {service: service, username: username, project_name: project_name}
  end

  def self.build_path(service : String, username : String, project_name : String)
    "/#{service}/#{username}/#{project_name}"
  end

  def self.versions_json(db : Queriable, service : String, username : String, project_name : String)
    versions = get_versions(db, service, username, project_name)
    path = build_path(service, username, project_name)
    {
      "versions" => versions.map do |version|
        {
          "name"     => "#{version.commit_id}",
          "url"      => "#{path}/index.html",
          "released" => !version.nightly,
        }
      end,
    }.to_json
  end

  def self.upsert_repo_status(db : Queriable, repo_id : RepoId)
    db.exec(<<-SQL, repo_id)
      INSERT INTO crystal_doc.repo_status (repo_id, last_commit, last_checked)
      VALUES ($1, 'UNUSED', now())
      ON CONFLICT(repo_id) DO UPDATE SET last_checked = EXCLUDED.last_checked
    SQL
  end

  def self.upsert_latest_version(db : Queriable, repo_id : RepoId, version_id : VersionId)
    db.exec(<<-SQL, repo_id, version_id)
      INSERT INTO crystal_doc.repo_latest_version (repo_id, latest_version)
      VALUES ($1, $2)
      ON CONFLICT(repo_id) DO UPDATE SET latest_version = EXCLUDED.latest_version
    SQL
  end

  def self.find(db : Queriable, query : String) : Array(Repo)?
    CrystalDoc::Repo.from_rs(db.query(<<-SQL, query))
      SELECT *
      FROM crystal_doc.repo
      WHERE levenshtein(repo.username, $1) <= 10 OR levenshtein(repo.project_name, $1) <= 10
      ORDER BY levenshtein(repo.project_name, $1)
      LIMIT 10;
    SQL
  end

  def self.recently_added(db : Queriable) : Array(Repo)?
    CrystalDoc::Repo.from_rs(db.query(<<-SQL))
      SELECT *
      FROM crystal_doc.repo
      ORDER BY id DESC
      LIMIT 10;
    SQL
  end

  def self.most_popular(db : Queriable) : Array(Repo)?
    CrystalDoc::Repo.from_rs(db.query(<<-SQL))
      SELECT crystal_doc.repo.*
      FROM crystal_doc.repo
      INNER JOIN crystal_doc.repo_statistics
        ON crystal_doc.repo.id = crystal_doc.repo_statistics.repo_id
      ORDER BY crystal_doc.repo_statistics.count DESC
      LIMIT 10;
    SQL
  end

  def versions(db : Queriable) : Array(RepoVersion)
    CrystalDoc::RepoVersion.from_rs(
      db.query "SELECT * FROM crystal_doc.repo_version WHERE repo_id = $1", id
    )
  end

  def versions_to_json(db : Queriable)
    {
      "versions" => versions(db).reverse.map do |version|
        {
          "name"     => "#{version.commit_id}",
          "url"      => "#{path}/#{version.commit_id}/",
          "released" => !version.nightly,
        }
      end,
    }.to_json
  end

  def status(db : Queriable) : RepoStatus
    CrystalDoc::RepoStatus.from_rs(
      db.query "SELECT * FROM crystal_doc.repo_status WHERE repo_id = $1", id
    )
  end

  def path
    "/#{service}/#{username}/#{project_name}"
  end
end
