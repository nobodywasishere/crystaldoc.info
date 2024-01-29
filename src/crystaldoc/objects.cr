module CrystalDoc
  struct Repo
    include ::DB::Serializable
    include ::DB::Serializable::NonStrict

    getter id : Int32
    getter service : String
    getter username : String
    getter project_name : String
    getter source_url : String
    getter build_type : String

    def initialize(@id, @service, @username, @project_name, @source_url, @build_type = "git")
    end

    def path
      "/#{service}/#{username}/#{project_name}"
    end
  end

  struct RepoVersion
    include ::DB::Serializable
    include ::DB::Serializable::NonStrict

    getter commit_id : String
    getter? nightly : Bool
    getter? valid : Bool
  end
end
