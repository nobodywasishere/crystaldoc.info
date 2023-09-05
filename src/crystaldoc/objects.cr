module CrystalDoc
  struct Repo
    include ::DB::Serializable
    include ::DB::Serializable::NonStrict

    getter service : String
    getter username : String
    getter project_name : String

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
