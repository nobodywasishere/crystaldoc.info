require "kemal"
require "db"
require "pg"
require "semantic_version"

get "/" do
  "CrystalDoc.info - Crystal Shard Documentation"
end

get "/:serv/:user/:proj" do |env|
  repo = CrystalDoc::Repo.from_kemal_env(env)
  unless repo.nil?
    repo = repo.first
  
    unless repo.versions.size > 0 && File.exists?("public/#{repo.path}/#{repo.versions.first}")
      puts CrystalDoc::Worker.generate_docs(repo)
    end
  
    env.redirect "/#{repo.path}/latest"
  end
end

get "/:serv/:user/:proj/latest" do |env|
  repo = CrystalDoc::Repo.from_kemal_env(env)
  unless repo.nil?
    repo = repo.first
    env.redirect "/#{repo.path}/index.html"
  end
end

get "/:serv/:user/:proj/versions.json" do |env|
  repo = CrystalDoc::Repo.from_kemal_env(env)
  unless repo.nil?
    repo = repo.first
  
    repo.versions_to_json
  end
end

get "/:serv/:user/:proj/new_version" do |env|
  new_version = env.params.query["new_version"]
end

get "/new_repository" do |env|
  url = env.params.query["repo_url"]

  #TODO: Need to handle URL redirects, is detectable with git ls-remote, just need to parse proper url out of output.  Not sure how to best structure the code.
  if !valid_vcs_url?(url)
    "Bad url: #{url}"
  elsif CrystalDoc::Queries.has_repo(url)
    "Docs already exist"
  else
    add_new_repo(url)
    "Repo added to database"
  end
rescue ex
  "Repository failed to be created: #{ex}"
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
  stdout = IO::Memory.new()
  unless git_ls_remote(repo_url, stdout)
    raise "git ls-remote failed"
  end
  tags_key = "refs/tags/"
  #stdio.each_line doesn't work for some reason
  stdout.to_s.each_line do |line|
    split_line = line.split('\t')
    hash = split_line[0]
    tag = split_line[1].lchop?(tags_key)
    unless tag.nil?
      yield hash, tag
    end
  end
end

def parse_repo_info(repo_url : String) : {service: String, username: String, project_name: String}
  uri = URI.parse(repo_url).normalize
  service = CrystalDoc::SERVICE_HOSTS[uri.host] || raise "No known service: #{uri.host}"
      
  path_fragments = uri.path.split('/')[1..]
  raise "Invalid url component: #{uri.path}" if path_fragments.size != 2

  username = path_fragments[0]
  project_name = path_fragments[1]

  { service: service, username: username, project_name: project_name }
end

def add_new_repo(repo_url : String)
  repo_info = parse_repo_info(repo_url)

  DB.open(ENV["POSTGRES_DB"]) do |db|
    db.transaction do |tx|
      conn = tx.connection
      repo_id = CrystalDoc::Queries.insert_repo(conn, repo_info[:service], repo_info[:username], repo_info[:project_name], repo_url)
      get_git_versions(repo_url) do |_, tag|
        CrystalDoc::Queries.insert_version(conn, repo_id, tag)
      end
      CrystalDoc::Queries.upsert_repo_status(conn, repo_id)
    end
  end
end
