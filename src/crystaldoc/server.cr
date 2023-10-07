require "kemal"
require "db"
require "pg"

serve_static({"gzip" => true, "dir_listing" => false})

# Export main CSS file

Dir.mkdir_p("public/css", 0o744)
File.write "public/css/style.css", CrystalDoc::Views::StyleTemplate.new

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
  unless CrystalDoc::Queries.repo_exists_and_valid(REPO_DB, env.params.url["serv"], env.params.url["user"], env.params.url["proj"])
    env.response.status_code = 404
    next
  end

  latest_version = CrystalDoc::Queries.latest_version(REPO_DB,
    env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
  )

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
  CrystalDoc::Queries.versions_json(REPO_DB,
    env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
  )
end

get "/random" do |env|
  repo = CrystalDoc::Queries.random_repo(REPO_DB)
  env.redirect repo.path
end

post "/search" do |env|
  query = env.params.body["q"]
  if query.includes? "/"
    user, proj = query.split("/")[0..1] # ameba:disable Lint/UselessAssign
    distinct = true                     # ameba:disable Lint/UselessAssign
  else
    user = query     # ameba:disable Lint/UselessAssign
    proj = query     # ameba:disable Lint/UselessAssign
    distinct = false # ameba:disable Lint/UselessAssign
  end
  render "src/views/search_results.ecr" unless query == ""
end

get "/jobs_queue" do
  render "src/views/jobs_queue_head.ecr", "src/views/layout.ecr"
end

post "/jobs_queue" do
  limit = 20 # ameba:disable Lint/UselessAssign
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
  Log.error { "NewRepo Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}" }
end

error 404 do |env|
  title = "" # ameba:disable Lint/UselessAssign
  msg = ""   # ameba:disable Lint/UselessAssign

  unless /(?:\/~?[a-zA-Z0-9\.\-_]+){4,}/.match(env.request.path)
    title = "This page doesn't exist" # ameba:disable Lint/UselessAssign
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  service, user, proj, version = env.request.path.split("/")[1..4]

  # Check if it's a valid repo / version
  unless CrystalDoc::Queries.repo_exists(REPO_DB, service, user, proj)
    title = "Repo doesn't exist" # ameba:disable Lint/UselessAssign
    msg = <<-MSG
    The repo '#{service}/#{user}/#{proj}' doesn't exist. You can add it by submitting the URL <a href='https://crystaldoc.info/#add-a-shard'>here</a>.
    MSG

    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  if version == "latest"
    title = "All repo versions failed to build docs"                                                # ameba:disable Lint/UselessAssign
    msg = "All of the versions for repo '#{service}/#{user}/#{proj}' failed to build documentation" # ameba:disable Lint/UselessAssign
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  unless CrystalDoc::Queries.repo_version_exists(REPO_DB, service, user, proj, version)
    title = "Version doesn't exist"                                                      # ameba:disable Lint/UselessAssign
    msg = "The version '#{version}' for repo '#{service}/#{user}/#{proj}' doesn't exist" # ameba:disable Lint/UselessAssign
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  # Check if doc generation is queued
  if CrystalDoc::DocJob.in_queue?(REPO_DB, service, user, proj, version)
    title = "Version in build queue"                                                             # ameba:disable Lint/UselessAssign
    msg = "The version '#{version}' for repo '#{service}/#{user}/#{proj}' is in the build queue" # ameba:disable Lint/UselessAssign
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  title = "Repo version failed to build" # ameba:disable Lint/UselessAssign

  # Shouldn't end up here
  render "src/views/404.ecr", "src/views/layout.ecr"
end
