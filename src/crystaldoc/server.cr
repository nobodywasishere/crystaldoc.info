require "kemal"
require "db"
require "pg"
require "semantic_version"
require "ecr"

require "./stats_handler"

# Need to create the doc.js
Dir.mkdir_p("public/css", 0o744)
File.write "public/css/style.css", CrystalDoc::Views::StyleTemplate.new

DB.open(ENV["POSTGRES_DB"]) do |db|
  add_handler CrystalDoc::StatsHandler.new(db)

  get "/" do
    render "src/views/main.ecr", "src/views/layouts/layout.ecr"
  end

  get "/:serv/:user/:proj" do |env|
    repo = CrystalDoc::Repo.from_kemal_env(db, env)
    env.redirect "#{repo.path}/latest"
  end

  get "/:serv/:user/:proj/latest" do |env|
    db.transaction do |tx|
      latest_version = CrystalDoc::RepoVersion.latest(db,
        env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
      )

      unless latest_version.nil?
        env.redirect "./#{latest_version.commit_id}/"
      end
    end
  end

  get "/:serv/:user/:proj/versions.json" do |env|
    repo = CrystalDoc::Repo.from_kemal_env(db, env)
    unless repo.nil?
      repo.versions_json(db)
    end
  end

  get "/:serv/:user/:proj/:version/" do |env|
    repo = CrystalDoc::Repo.from_kemal_env(db, env)
    version = CrystalDoc::RepoVersion.find(db, repo.id, env.params.url["version"])
    unless repo.nil? || version.nil? || File.exists?("public#{repo.path}/#{env.params.url["version"]}")
      CrystalDoc::Worker.generate_docs(repo, version)
    end

    env.redirect("#{repo.path}/#{version.commit_id}/index.html")
  end

  post "/new_repository" do |env|
    url = env.params.body["url"].as(String)

    # TODO: Need to handle URL redirects, is detectable with git ls-remote, just need to parse proper url out of output.  Not sure how to best structure the code.
    if !CrystalDoc::Git.valid_vcs_url?(url)
      "Bad url: #{url}"
    elsif CrystalDoc::Repo.exists(db, url)
      "Docs already exist"
    else
      CrystalDoc::Repo.add_new_repo(db, url)
      "Repo added to database"
    end
    # rescue ex
    #   "Repository failed to be created: #{ex}"
  end

  post "/refresh_versions" do |env|
    url = env.params.body["url"].as(String)
    if !CrystalDoc::Git.valid_vcs_url?(url)
      "Bad url: #{url}"
    else
      CrystalDoc::Repo.refresh_versions(db, url)
      "Versions refreshed"
    end
  end

  post "/search" do |env|
    query = env.params.body["q"]
    render "src/views/results.ecr" unless query == ""
  end

  get "/pending_jobs" do |env|
    limit = env.params.query["limit"]?.try &.to_i32

    html = ""
    jobs = CrystalDoc::DocJob.select(db, limit)
    html = ECR.render("src/views/job_table.ecr")
    html
  end
end

Kemal.run
