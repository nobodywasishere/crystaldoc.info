require "db"
require "pg"
require "json"

module CrystalDoc
  SERVICE_HOSTS = {
    "github.com" => "github",
    "gitlab.com" => "gitlab",
    "git.sr.ht" => "git-sr-ht",
    "hg.sr.ht" => "hg-sr-ht",
    "codeberg.org" => "codeberg",
  }

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
      service = SERVICE_HOSTS[uri.host] || raise "No known service: #{uri.host}"
      
      path_fragments = uri.path.split('/')[1..]
      raise "Invalid url component: #{uri.path}" if path_fragments.size != 2

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

  class RepoLatestVersion
    include DB::Serializable

    property id : Int32
    property repo_id : Int32
    property latest_version : Int32

    def set_version(version : RepoVersion)
      DB.open(ENV["POSTGRES_DB"]) do |db|
        db.exec "UPDATE crystal_doc.repo_latest_version; SET latest_version = $1; WHERE id = $2", version.id, id
      end
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

    property id : Int32
    property version_id : Int32
    property queue_time : Time
  end
end
