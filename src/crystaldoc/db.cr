require "db"
require "pg"
require "json"

module CrystalDoc
  SERVICE_HOSTS = {
    "github.com" => "github",
    "gitlab.com" => "gitlab",
    "sr.ht" => "srht"
  }

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

    property id : Int32
    property repo_id : Int32
    property commit_id : String
    property nightly : Bool

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