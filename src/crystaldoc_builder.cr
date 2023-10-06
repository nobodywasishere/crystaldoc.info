require "./crystaldoc"

Dir.mkdir_p "./logs"
log_file = File.new("./logs/builder.log", "a+")

Log.setup(:info, Log::IOBackend.new(log_file))

REPO_DB = DB.open(ENV["POSTGRES_DB"])

# Queue builders
(1..ENV["CRYSTAL_WORKERS"]?.try &.to_i || 4).each do
  spawn do
    builder = CrystalDoc::Builder.new(REPO_DB)
    builder.search_for_jobs
  end
end

sleep
