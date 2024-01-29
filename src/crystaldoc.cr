require "log"
require "db"
require "pg"
require "http/client"
require "uri"
require "yaml"

module CrystalDoc
  VERSION = "0.1.0"

  alias Queriable = DB::Connection | DB::Database
end

require "./crystaldoc/config"
require "./crystaldoc/vcs"
require "./crystaldoc/ext"
require "./crystaldoc/html"
require "./crystaldoc/views"
require "./crystaldoc/objects"
require "./crystaldoc/queries"
require "./crystaldoc/doc_job"
require "./crystaldoc/builder"
require "./crystaldoc/searcher"
