require "db"
require "pg"
require "json"

module CrystalDoc
  alias RepoId = Int32
  alias VersionId = Int32

  alias Queriable = DB::QueryMethods(DB::Statement) | DB::QueryMethods(DB::PoolStatement)

  class Queries
    def self.has_repo(repo_url : String)
      DB.open(ENV["POSTGRES_DB"]) do |db|
        db.scalar("SELECT EXISTS(SELECT 1 FROM crystal_doc.repo WHERE repo.source_url = $1)", repo_url).as(Bool)
      end
    end

    def self.insert_repo(db : Queriable, service : String, username : String, project_name : String, source_url : String) : RepoId
      db.scalar(
        "INSERT INTO crystal_doc.repo (service, username, project_name, source_url)
         VALUES ($1, $2, $3, $4)
         RETURNING id",
        service, username, project_name, source_url).as(Int32)
    end

    def self.insert_version(db : Queriable, repo_id : RepoId, commit_id : String, nightly : Bool = false) : VersionId
      db.scalar(
        "INSERT INTO crystal_doc.repo_version (repo_id, commit_id, nightly)
         VALUES ($1, $2, $3)
         RETURNING id",
        repo_id, commit_id, nightly).as(Int32)
    end

    def self.insert_doc_job(db : Queriable, version_id : VersionId, priority : Int32) : Int32
      db.scalar(
        "INSERT INTO crystal_doc.doc_job (version_id, priority)
         VALUES ($1, $2)
         RETURNING id",
         version_id, priority).as(Int32)
    end

    def self.upsert_repo_status(db : Queriable, repo_id : RepoId)
      db.exec(
        "INSERT INTO crystal_doc.repo_status (repo_id, last_commit, last_checked)
         VALUES ($1, 'UNUSED', now())
         ON CONFLICT(repo_id) DO UPDATE SET last_checked = EXCLUDED.last_checked",
        repo_id)
    end

    def self.upsert_latest_version(db : Queriable, repo_id : RepoId, version_id : VersionId)
      db.exec(
        "INSERT INTO crystal_doc.repo_latest_version (repo_id, latest_version)
         VALUES ($1, $2)
         ON CONFLICT(repo_id) DO UPDATE SET latest_version = EXCLUDED.latest_version",
        repo_id, version_id)
    end

    def self.get_repos(db : Queriable) : Array(Repo)
      CrystalDoc::Repo.from_rs(db.query("SELECT * FROM crystal_doc.repo"))
    end

    def self.get_latest_version(db : Queriable, repo_id : RepoId) : RepoVersion?
      db.query_one(
        "SELECT repo_version.id, repo_version.repo_id, repo_version.commit_id, repo_version.nightly
         FROM crystal_doc.repo_version INNER JOIN crystal_doc.repo_latest_version
         ON repo_version.id = repo_latest_version.latest_version
         WHERE repo_latest_version.repo_id = $1",
        repo_id, as: RepoVersion)
    end

    def self.get_latest_version(db : Queriable, service : String, username : String, project_name : String) : RepoVersion?
      db.query_one(
        "SELECT repo_version.id, repo_version.repo_id, repo_version.commit_id, repo_version.nightly
         FROM crystal_doc.repo_version INNER JOIN crystal_doc.repo_latest_version
         ON repo_version.id = repo_latest_version.latest_version
         INNER JOIN crystal_doc.repo
         ON repo.id = repo_latest_version.repo_id
         WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3",
        service, username, project_name, as: RepoVersion)
    end

    def self.get_versions(db : Queriable, repo_id : RepoId) : Array(Repo)?
      CrystalDoc::RepoVersion.from_rs(
          db.query(
          "SELECT repo_version.id, repo_version.repo_id, repo_version.commit_id, repo_version.nightly
           FROM crystal_doc.repo_version
           WHERE repo_id = $1", id))
    end
  end

  class Repo
    include DB::Serializable

    getter id : Int32
    getter service : String
    getter username : String
    getter project_name : String
    getter source_url : String

    def initialize(@id : Int32, @service : String, @username : String, @project_name : String, @source_url : String)
    end

    def path
      "/#{service}/#{username}/#{project_name}"
    end

    def self.uri_to_service(uri : URI) : String
      if (host = uri.host).nil?
        raise "No host: #{uri}"
      end

      host.gsub(/\.com$/, "").gsub(/\./, "-")
    end

    def self.from_kemal_env(env) : Array(Repo) | Nil
      DB.open(ENV["POSTGRES_DB"]) do |db|
        service = env.params.url["serv"]
        username = env.params.url["user"]
        project_name = env.params.url["proj"]
        CrystalDoc::Repo.from_rs(
          db.query(
            "SELECT * FROM crystal_doc.repo WHERE service = $1 AND username = $2 AND project_name = $3",
            service, username, project_name
          )
        )
      end
    end

    def self.create(source_url : String)
      uri = URI.parse(source_url).normalize

      path_fragments = uri.path.split('/')[1..]
      raise "Invalid url component: #{uri.path}" if path_fragments.size != 2

      service = self.uri_to_service(uri)
      username = path_fragments[0]
      project_name = path_fragments[1]

      DB.open(ENV["POSTGRES_DB"]) do |db|
        id = db.exec(
          "INSERT INTO crystal_doc.repo (service, username, project_name, source_url) VALUES ($1, $2, $3, $4) RETURNING id",
          service, username, project_name, uri.to_s
        ).last_insert_id.to_i32
        Repo.new(id, service, username, project_name, source_url)
      end
    end

    def versions : Array(RepoVersion)
      DB.open(ENV["POSTGRES_DB"]) do |db|
        CrystalDoc::RepoVersion.from_rs(
          db.query "SELECT * FROM crystal_doc.repo_version WHERE repo_id = $1", id
        )
      end
    end

    def versions_to_json
      {
        "versions" => versions.map do |version|
          {
            "name" => "#{version.commit_id}",
            "url" => "#{path}/index.html",
            "released" => !version.nightly
          }
        end
      }.to_json
    end

    def status : RepoStatus
      DB.open(ENV["POSTGRES_DB"]) do |db|
        CrystalDoc::RepoStatus.from_rs(
          db.query "SELECT * FROM crystal_doc.repo_status WHERE repo_id = $1", id
        )
      end
    end

    def self.get_latest_version(db : Queriable, service : String, username : String, project_name : String) : RepoVersion?
      db.query_one(
        "SELECT repo_version.id, repo_version.repo_id, repo_version.commit_id, repo_version.nightly
         FROM crystal_doc.repo_version INNER JOIN crystal_doc.repo_latest_version
         ON repo_version.id = repo_latest_version.latest_version
         INNER JOIN crystal_doc.repo
         ON repo.id = repo_latest_version.repo_id
         WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3",
        service, username, project_name, as: RepoVersion)
    end

    def self.get_versions(db : Queriable, service : String, username : String, project_name : String) : Array(RepoVersion)?
      db.query(
        "SELECT repo_version.id, repo_version.repo_id, repo_version.commit_id, repo_version.nightly
         FROM crystal_doc.repo_version
         WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3",
        service, username, project_name,) { |rs| CrystalDoc::RepoVersion.from_rs(rs) }
    end

    def self.parse_url(repo_url : String) : {service: String, username: String, project_name: String}
      uri = URI.parse(repo_url).normalize
      service = uri_to_service(uri)
      
      path_fragments = uri.path.split('/')[1..]
      raise "Invalid url component: #{uri.path}" if path_fragments.size != 2

      username = path_fragments[0]
      project_name = path_fragments[1]

      { service: service, username: username, project_name: project_name }
    end

    def self.build_path(service : String, username : String, project_name : String)
      "/#{service}/#{username}/#{project_name}"
    end

    def self.build_versions_json(db : Queriable, service : String, username : String, project_name : String)
      versions = get_versions(db, service, username, project_name)
      path = build_path(service, username, project_name)
      {
        "versions" => versions.map do |version|
          {
            "name" => "#{version.commit_id}",
            "url" => "#{path}/index.html",
            "released" => !version.nightly
          }
        end
      }.to_json
    end
  end

  class RepoVersion
    include DB::Serializable

    getter id : Int32
    getter repo_id : Int32
    getter commit_id : String
    getter nightly : Bool

    def initialize(@id : Int32, @repo_id : Int32, @commit_id : String, @nightly : Bool)
    end

    def self.create(repo : Repo, commid_id : String, nightly : Bool)

    end

    def self.create(repo_id, version)

    end
  end

  class RepoStatus
    include DB::Serializable

    property id : Int32
    property repo_id : Int32
    property last_commit : String
    property last_checked : Time
  end

  class DocJob
    include DB::Serializable

    # Job metadata
    getter id : Int32
    getter priority : Int32
    getter job_age : PG::Interval

    # Job data
    getter source_url : String
    getter commit_id : String

    # Should only be called from a transaction
    def self.take(db : Queriable) : DocJob
      db.query_one(
        "DELETE FROM
         crystal_doc.doc_job
         USING (
          SELECT doc_job.id, doc_job.priority, age(now(), doc_job.queue_time) as job_age, sub.source_url, sub.commit_id
          FROM crystal_doc.doc_job
          INNER JOIN LATERAL (
              SELECT repo_version.id, repo_version.repo_id, repo_version.commit_id, repo.source_url
              FROM crystal_doc.repo_version
              LEFT JOIN crystal_doc.repo
              ON repo_version.repo_id = repo.id
              ) sub ON doc_job.version_id = sub.id
          ORDER BY doc_job.priority DESC, job_age DESC
          LIMIT 1 FOR UPDATE OF doc_job SKIP LOCKED
         ) taken_job
         WHERE taken_job.id = doc_job.id
         RETURNING taken_job.*", as: DocJob)
    end

    def self.select(db : Queriable, limit : Int32? = nil) : Array(DocJob)?
      db.query(
        "SELECT job.id, job.priority, age(now(), job.queue_time) as job_age, repo.source_url, repo_version.commit_id
         FROM crystal_doc.repo_version INNER JOIN crystal_doc.doc_job job
         ON repo_version.id = job.version_id
         INNER JOIN crystal_doc.repo
         ON repo.id = repo_version.repo_id
         ORDER BY job.priority DESC, job_age DESC LIMIT $1", limit) { |rs| CrystalDoc::DocJob.from_rs(rs) }
    end
  end
end
