require "kemal"
require "db"
require "pg"
require "semantic_version"
require "ecr"

# Need to create the doc.js
Dir.mkdir_p("public/css", 0o744)
Dir.mkdir_p("public/js", 0o744)
File.write "public/css/style.css", CrystalDoc::Views::StyleTemplate.new
File.write "public/js/doc.js", CrystalDoc::Views::JsTypeTemplate.new

get "/" do
  render "src/views/main.ecr", "src/views/layouts/layout.ecr"
end

get "/:serv/:user/:proj" do |env|
  repo = CrystalDoc::Repo.from_kemal_env(env)
  env.redirect "#{repo.path}/latest"
end

get "/:serv/:user/:proj/latest" do |env|
  DB.open(ENV["POSTGRES_DB"]) do |db|
    db.transaction do |tx|
      latest_version = CrystalDoc::Queries.get_latest_version(db,
        env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
      )

      unless latest_version.nil?
        env.redirect "./#{latest_version.commit_id}/"
      end
    end
  end
end

get "/:serv/:user/:proj/versions.json" do |env|
  repo = CrystalDoc::Repo.from_kemal_env(env)
  unless repo.nil?
    repo.versions_to_json
  end
end

get "/:serv/:user/:proj/:version/" do |env|
  repo = CrystalDoc::Repo.from_kemal_env(env)
  version = CrystalDoc::RepoVersion.find(repo.id, env.params.url["version"])
  unless repo.nil? || version.nil? || File.exists?("public#{repo.path}/#{env.params.url["version"]}")
    CrystalDoc::Worker.generate_docs(repo, version)
  end

  env.redirect("#{repo.path}/#{version.commit_id}/index.html")
end

post "/new_repository" do |env|
  url = env.params.body["url"].as(String)

  # TODO: Need to handle URL redirects, is detectable with git ls-remote, just need to parse proper url out of output.  Not sure how to best structure the code.
  if !valid_vcs_url?(url)
    "Bad url: #{url}"
  elsif CrystalDoc::Queries.has_repo(url)
    "Docs already exist"
  else
    add_new_repo(url)
    "Repo added to database"
  end
  # rescue ex
  #   "Repository failed to be created: #{ex}"
end

get "/pending_jobs" do |env|
  limit = env.params.query["limit"]?.try &.to_i32

  html = ""
  DB.open(ENV["POSTGRES_DB"]) do |db|
    jobs = CrystalDoc::DocJob.select(db, limit)
    html = ECR.render("src/views/job_table.ecr")
  end
  html
end

Kemal.run

def valid_vcs_url?(repo_url : String) : Bool
  git_ls_remote(repo_url)
  # Mercurial - hg identify
end

def git_ls_remote(repo_url : String, output : Process::Stdio = Process::Redirect::Close) : Bool
  Process.run("git", ["ls-remote", repo_url], output: output).success?
end

def get_git_versions(repo_url : String, &)
  stdout = IO::Memory.new
  unless git_ls_remote(repo_url, stdout)
    raise "git ls-remote failed"
  end
  tags_key = "refs/tags/"
  # stdio.each_line doesn't work for some reason, had to convert to string first
  stdout.to_s.each_line do |line|
    split_line = line.split('\t')
    hash = split_line[0]
    tag = split_line[1].lchop?(tags_key)
    unless tag.nil?
      yield hash, tag
    end
  end
end

LATEST_PRIORITY     = 1000
HISTORICAL_PRIORITY =  -10

def add_new_repo(repo_url : String)
  repo_info = CrystalDoc::Repo.parse_url(repo_url)

  DB.open(ENV["POSTGRES_DB"]) do |db|
    db.transaction do |tx|
      conn = tx.connection
      # Insert repo into database
      repo_id = CrystalDoc::Queries.insert_repo(conn, repo_info[:service], repo_info[:username], repo_info[:project_name], repo_url)

      # Identify repo versions, and add to database
      versions = Array({id: Int32, normalized_form: SemanticVersion}).new
      get_git_versions(repo_url) do |_, tag|
        normalized_version = SemanticVersion.parse(tag.lchop('v'))

        # Don't record version until we've tried to parse the version
        version_id = CrystalDoc::Queries.insert_version(conn, repo_id, tag)
        versions.push({id: version_id, normalized_form: normalized_version})
      rescue ArgumentError
        puts "Unknown version format \"#{tag}\" from repo \"#{repo_url}\""
      end

      versions = versions.sort_by { |version| version[:normalized_form] }

      # Add doc generation jobs to the database queue, prioritized newest to oldest
      versions.each_with_index do |version, index|
        priority = index == versions.size - 1 ? LATEST_PRIORITY : (versions.size - 1 - index) * HISTORICAL_PRIORITY
        CrystalDoc::Queries.insert_doc_job(conn, version[:id], priority)
      end

      # Record latest repo version
      if versions.size > 0
        CrystalDoc::Queries.upsert_latest_version(conn, repo_id, versions[-1][:id])
      end

      # Update the repo status (records the last time the repo was processed)
      CrystalDoc::Queries.upsert_repo_status(conn, repo_id)
    end
  end
end
