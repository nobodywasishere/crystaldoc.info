require "db"
require "pg"
require "json"

module CrystalDoc
  alias RepoId = Int32
  alias VersionId = Int32

  alias Queriable = DB::QueryMethods(DB::Statement) | DB::QueryMethods(DB::PoolStatement)
end

require "./objects/doc_job"
require "./objects/repo_status"
require "./objects/repo_version"
require "./objects/repo"
