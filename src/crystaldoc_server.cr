require "kemal"
require "db"
require "pg"

require "./crystaldoc"

serve_static({"gzip" => true, "dir_listing" => false})

Dir.mkdir_p("public/css", 0o744)
File.write "public/css/style.css", CrystalDoc::Views::StyleTemplate.new

REPO_DB = DB.open(ENV["POSTGRES_DB"])

cache_vals = {} of String => String?
cache_times = {} of String => Time
cache_time = Time::Span.new(minutes: 1)

def cache(name : String, time : Time::Span, cache_vals, cache_times, &) : String?
  if !cache_vals.keys.includes?(name) || (Time.utc - cache_times[name]).abs > time
    cache_vals[name] = yield
    cache_times[name] = Time.utc
  end

  cache_vals[name]
end

get "/" do
  repo_list = cache("repo_list", cache_time, cache_vals, cache_times) {
    CrystalDoc::Views::RepoList.new(
      CrystalDoc::Queries.recently_added_repos(REPO_DB, 10)
    ).to_s
  }

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
  cache_name = "latest_version_#{env.params.url["serv"]}_#{env.params.url["user"]}_#{env.params.url["proj"]}"
  latest_version = cache(cache_name, cache_time, cache_vals, cache_times) {
    CrystalDoc::Queries.latest_version(REPO_DB,
      env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
    )
  }

  if latest_version.nil?
    env.response.status_code = 404
  else
    env.redirect "./#{latest_version}/index.html"
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
  cache_name = "versions_json_#{env.params.url["serv"]}_#{env.params.url["user"]}_#{env.params.url["proj"]}"
  cache(cache_name, cache_time, cache_vals, cache_times) {
    CrystalDoc::Queries.versions_json(REPO_DB,
      env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
    )
  }
end

get "/random" do |env|
  repos = CrystalDoc::Queries.rs_to_repo(REPO_DB.query(<<-SQL))
    SELECT DISTINCT repo.service, repo.username, repo.project_name, RANDOM()
    FROM crystal_doc.repo
    INNER JOIN crystal_doc.repo_version
      ON repo_version.repo_id = repo.id
    WHERE repo_version.valid = true
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
  render "src/views/jobs_queue_head.ecr", "src/views/layout.ecr"
end

post "/jobs_queue" do
  limit = 20
  render "src/views/jobs_queue_body.ecr"
end

post "/new_repository" do |env|
  url = env.params.body["url"].as(String)

  if CrystalDoc::Queries.repo_exists(REPO_DB, url)
    "Repository exists"
  else
    vcs = CrystalDoc::VCS.new(url)
    vcs.parse(REPO_DB)
  end
rescue ex
  puts "NewRepo Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}"
end

error 404 do |env|
  title = "This page doesn't exist"
  msg = ""

  unless /(?:\/~?[a-zA-Z0-9\.\-_]+){4,}/.match(env.request.path)
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  service, user, proj, version = env.request.path.split("/")[1..4]

  # Check if it's a valid repo / version
  unless CrystalDoc::Queries.repo_exists(REPO_DB, service, user, proj)
    title = "Repo doesn't exist"
    msg = "The repo '#{service}/#{user}/#{proj}' doesn't exist"
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  unless CrystalDoc::Queries.repo_version_exists(REPO_DB, service, user, proj, version)
    title = "Version doesn't exist"
    msg = "The version '#{version}' for repo '#{service}/#{user}/#{proj}' doesn't exist"
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  # Check if doc generation in progress

  # Check if doc generation is queued
  if CrystalDoc::DocJob.in_queue?(REPO_DB, service, user, proj, version)
    title = "Version in build queue"
    msg = "The version '#{version}' for repo '#{service}/#{user}/#{proj}' is in the build queue"
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  # Shouldn't end up here
  render "src/views/404.ecr", "src/views/layout.ecr"
end

Kemal.run
