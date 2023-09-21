require "./crystaldoc"
require "option_parser"

REPO_DB = DB.open(ENV["POSTGRES_DB"])

cmd = ""
source = ""
repo = ["", "", ""]
version = ""

OptionParser.parse do |parser|
  parser.on "regenerate-all", "Regenerate all repo docs as doc jobs" do
    cmd = "regenerate-all"
  end

  parser.on "regenerate", "Regenerate repo doc version" do
    cmd = "regenerate"
    parser.on("--repo=REPO", "Repo triad") { |s| repo = s.split("/") }
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
  builder = CrystalDoc::Builder.new(source, repo[0], repo[1], repo[2], version)
  builder.build
else
  puts "Unknown cmd #{cmd.inspect}"
  exit 1
end
