class CrystalDoc::RepoStatus
  include DB::Serializable

  property id : Int32
  property repo_id : Int32
  property last_commit : String
  property last_checked : Time
end
