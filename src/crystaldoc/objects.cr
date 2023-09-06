module CrystalDoc
  struct Repo
    include ::DB::Serializable
    include ::DB::Serializable::NonStrict

    getter service : String
    getter username : String
    getter project_name : String

    def initialize(@service : String, @username : String, @project_name : String)
    end

    def path
      "/#{service}/#{username}/#{project_name}"
    end
  end

  struct RepoVersion
    include ::DB::Serializable
    include ::DB::Serializable::NonStrict

    getter commit_id : String
    getter nightly : Bool
  end
end
