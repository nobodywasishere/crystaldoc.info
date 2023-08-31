module CrystalDoc
  VERSION = "0.1.0"
end

alias Queriable = DB::Connection | DB::Database

require "./crystaldoc/vcs"
require "./crystaldoc/html"
require "./crystaldoc/views"
require "./crystaldoc/queries"
require "./crystaldoc/stats_handler"
require "./crystaldoc/docs_handler"
require "./crystaldoc/docs_builder"
require "./crystaldoc/server"
