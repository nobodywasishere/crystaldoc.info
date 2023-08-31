require "kemal"
require "db"
require "pg"

serve_static({"gzip" => true, "dir_listing" => false})
add_handler CrystalDoc::StatsHandler.new, 1
add_handler CrystalDoc::DocsHandler.new, 1

Dir.mkdir_p("public/css", 0o744)
File.write "public/css/style.css", CrystalDoc::Views::StyleTemplate.new

DB.open(ENV["POSTGRES_DB"]) do |db|
  get "/" do
    render "src/views/main.ecr", "src/views/layout.ecr"
  end

  get "/:serv/:user/:proj" do |env|
    env.redirect "#{env.request.path}/latest"
  end

  get "/:serv/:user/:proj/latest" do |env|
    latest_version = CrystalDoc::Queries.latest_version(db,
      env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
    )

    unless latest_version.nil?
      env.redirect "./#{latest_version}/index.html"
    else
      "No versions for #{env.request.path}"
    end
  end

  get "/:serv/:user/:proj/:version" do |env|
    path = env.request.path
    unless path.ends_with? "/"
      path += "/"
    end

    env.redirect "#{path}index.html"
  end

  get "/:serv/:user/:proj/versions.json" do |env|
    CrystalDoc::Queries.versions_json(db,
      env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
    )
  end

  get "/random" do |env|
    repos = CrystalDoc::Queries.rs_to_repo(db.query(<<-SQL))
      SELECT repo.service, repo.username, repo.project_name
      FROM crystal_doc.repo
      ORDER BY RANDOM()
      LIMIT 1;
    SQL

    if repos.size > 0
      env.redirect repos.first["path"]
    end
  end

  post "/search" do |env|
    query = env.params.body["q"]
    render "src/views/search_results.ecr" unless query == ""
  end

  post "/new_repository" do |env|
    url = env.params.body["url"].as(String)

    if CrystalDoc::Queries.repo_exists(db, url)
      "Repository exists"
    else
      vcs = CrystalDoc::VCS.new(url)
      vcs.parse(db)
    end
  end
end

Kemal.run
