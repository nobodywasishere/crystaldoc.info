require "kemal"
require "db"
require "pg"

require "./crystaldoc"

serve_static({"gzip" => true, "dir_listing" => false})

Dir.mkdir_p("public/css", 0o744)
File.write "public/css/style.css", CrystalDoc::Views::StyleTemplate.new

DB.open(ENV["POSTGRES_DB"]) do |db|
  get "/" do
    render "src/views/main.ecr", "src/views/layout.ecr"
  end

  get "/:serv/:user/:proj" do |env|
    path = env.request.path
    unless path.ends_with? "/"
      path += "/"
    end

    env.redirect "#{path}latest"
  end

  get "/:serv/:user/:proj/latest" do |env|
    latest_version = CrystalDoc::Queries.latest_version(db,
      env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
    )

    unless latest_version.nil?
      env.redirect "./#{latest_version}/index.html"
    else
      env.response.status_code = 404
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
    if query.includes? "/"
      user, proj = query.split("/")[0..1]
      proj = user if proj == ""
    else
      user = query
      proj = query
    end
    render "src/views/search_results.ecr" unless query == ""
  end

  get "/jobs_queue" do
    limit = 20
    render "src/views/jobs_queue.ecr", "src/views/layout.ecr"
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

  error 404 do |env|
    title = "This page doesn't exist"
    msg = ""

    unless /(?:\/~?[a-zA-Z0-9\.\-_]+){4,}/.match(env.request.path)
      next render "src/views/404.ecr", "src/views/layout.ecr"
    end

    service, user, proj, version = env.request.path.split("/")[1..4]

    # Check if it's a valid repo / version
    unless CrystalDoc::Queries.repo_exists(db, service, user, proj)
      title = "Repo doesn't exist"
      msg = "The repo '#{service}/#{user}/#{proj}' doesn't exist"
      next render "src/views/404.ecr", "src/views/layout.ecr"
    end

    unless CrystalDoc::Queries.repo_version_exists(db, service, user, proj, version)
      title = "Version doesn't exist"
      msg = "The version '#{version}' for repo '#{service}/#{user}/#{proj}' doesn't exist"
      next render "src/views/404.ecr", "src/views/layout.ecr"
    end

    # Check if doc generation in progress

    # Check if doc generation is queued
    if CrystalDoc::DocJob.in_queue?(db, service, user, proj, version)
      title = "Version in build queue"
      msg = "The version '#{version}' for repo '#{service}/#{user}/#{proj}' is in the build queue"
      next render "src/views/404.ecr", "src/views/layout.ecr"
    end

    # Shouldn't end up here
    render "src/views/404.ecr", "src/views/layout.ecr"
  end
end

Kemal.run
