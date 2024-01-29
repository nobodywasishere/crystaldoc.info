require "option_parser"
require "../crystaldoc"
require "./server"

Config  = CrystalDoc::Config.from_yaml(File.read("./config.yml"))
REPO_DB = DB.open(Config.postgres_url)

cmd = ""
source = ""
version = ""
workers = 4

OptionParser.parse do |parser|
  parser.on "add-featured", "Add repo to featured" do
    cmd = "add-featured"
    parser.on("--source=SOURCE_URL", "Repo git URL") { |t| source = t }
  end

  parser.on "remove-featured", "Remove repo from featured" do
    cmd = "remove-featured"
    parser.on("--source=SOURCE_URL", "Repo git URL") { |t| source = t }
  end

  parser.on "regenerate-all", "Regenerate all repo docs as doc jobs" do
    cmd = "regenerate-all"
  end

  parser.on "regenerate", "Regenerate repo doc version" do
    cmd = "regenerate"
    parser.on("--version=VERSION", "Repo git tag") { |w| version = w }
    parser.on("--source=SOURCE_URL", "Repo git URL") { |t| source = t }
  end

  parser.on "update-repo-versions", "Use the searcher to search for new repo versions" do
    cmd = "update-repo-versions"
    parser.on("--source=SOURCE_URL", "Repo git URL") { |t| source = t }
  end

  parser.on "server", "Kemal server" do
    cmd = "server"
  end

  parser.on "builder", "Docs builder" do
    cmd = "builder"
    parser.on("--workers=COUNT", "Number of workers (defaults to 4)") { |c| workers = c.to_i }
  end

  parser.on "searcher", "Docs searcher" do
    cmd = "searcher"
    parser.on("--workers=COUNT", "Number of workers (defaults to 4)") { |c| workers = c.to_i }
  end

  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
end

case cmd
when "add-featured"
  REPO_DB.transaction do |tx|
    conn = tx.connection

    repo_id = CrystalDoc::Queries.get_repo_id(conn, source)
    CrystalDoc::Queries.add_featured_repo(conn, repo_id)
  end
when "remove-featured"
  REPO_DB.transaction do |tx|
    conn = tx.connection

    repo_id = CrystalDoc::Queries.get_repo_id(conn, source)
    CrystalDoc::Queries.remove_featured_repo(conn, repo_id)
  end
when "regenerate-all"
  versions = REPO_DB.query_all(<<-SQL, as: Int32)
    SELECT repo_version.id
    FROM crystal_doc.repo_version;
  SQL

  versions.each do |v|
    next if CrystalDoc::DocJob.in_queue?(REPO_DB, v)
    CrystalDoc::Queries.insert_doc_job(REPO_DB, v, 0)
  end
when "update-repo-versions"
  REPO_DB.transaction do |tx|
    conn = tx.connection

    repo = CrystalDoc::Queries.repo_from_source(conn, source).first

    searcher = CrystalDoc::CLI::Searcher.new(0)
    searcher.update_repo(conn, repo)
  end
when "regenerate"
  REPO_DB.transaction do |tx|
    conn = tx.connection

    repo = CrystalDoc::Queries.repo_from_source(conn, source).first

    unless CrystalDoc::Queries.repo_version_exists(conn, repo.service, repo.username, repo.project_name, version)
      puts "Version #{version} for repo #{repo.path} doesn't exist"
      exit 1
    end

    builder = CrystalDoc::Builder.new(0)
    res = builder.build(repo, version)

    if res
      CrystalDoc::Queries.mark_version_valid(
        conn, version, repo.service, repo.username, repo.project_name
      )

      CrystalDoc::DocJob.remove(conn, source, version)
    else
      CrystalDoc::Queries.mark_version_invalid(
        conn, version, repo.service, repo.username, repo.project_name
      )
    end
  end
when "server"
  Dir.mkdir_p "./logs"
  log_file = File.new("./logs/server.log", "a+")

  Log.setup(:info, Log::IOBackend.new(log_file))
  Kemal.config.logger = Kemal::LogHandler.new(log_file)
  Kemal.config.env = "production"

  Kemal.run
when "builder"
  Dir.mkdir_p "./logs"
  log_file = File.new("./logs/builder.log", "a+")

  Log.setup(:info, Log::IOBackend.new(log_file))

  (1..workers).each do |idx|
    spawn do
      builder = CrystalDoc::Builder.new(idx)
      builder.search_for_jobs(REPO_DB)
    end
  end

  sleep
when "searcher"
  Dir.mkdir_p "./logs"
  log_file = File.new("./logs/searcher.log", "a+")

  Log.setup(:info, Log::IOBackend.new(log_file))

  (1..workers).each do |idx|
    spawn do
      searcher = CrystalDoc::CLI::Searcher.new(idx)
      searcher.search_for_jobs(REPO_DB)
    end
  end

  sleep
else
  puts "Unknown cmd #{cmd.inspect}"
  exit 1
end
