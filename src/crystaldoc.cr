require "db"
require "pg"

module CrystalDoc
  VERSION = "0.1.0"
end

alias Queriable = DB::Connection | DB::Database

require "./crystaldoc/vcs"
require "./crystaldoc/html"
require "./crystaldoc/views"
require "./crystaldoc/queries"
require "./crystaldoc/doc_job"
require "./crystaldoc/builder"
