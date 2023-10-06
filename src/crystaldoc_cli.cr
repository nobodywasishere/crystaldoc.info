require "./crystaldoc"
require "option_parser"

REPO_DB = DB.open(ENV["POSTGRES_DB"])

cmd = ""
source = ""
version = ""

OptionParser.parse do |parser|
  parser.on "regenerate-all", "Regenerate all repo docs as doc jobs" do
    cmd = "regenerate-all"
  end

  parser.on "regenerate", "Regenerate repo doc version" do
    cmd = "regenerate"
    parser.on("--version=VERSION", "Repo git tag") { |w| version = w }
    parser.on("--source=SOURCE_URL", "Repo git URL") { |t| source = t }
  end
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
end

case cmd
when "regenerate-all"
  versions = REPO_DB.query_all(<<-SQL, as: Int32)
    SELECT repo_version.id
    FROM crystal_doc.repo_version;
  SQL

  versions.each do |version|
    next if CrystalDoc::DocJob.in_queue?(REPO_DB, version)
    CrystalDoc::Queries.insert_doc_job(REPO_DB, version, 0)
  end
when "regenerate"
  REPO_DB.transaction do |tx|
    conn = tx.connection

    repo = CrystalDoc::Queries.repo_from_source(conn, source).first

    unless CrystalDoc::Queries.repo_version_exists(conn, repo.service, repo.username, repo.project_name, version)
      puts "Version #{version} for repo #{repo.path} doesn't exist"
      exit 1
    end

    builder = CrystalDoc::Builder.new(REPO_DB)
    res = builder.build_git(repo, version)

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
else
  puts "Unknown cmd #{cmd.inspect}"
  exit 1
end
