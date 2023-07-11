require "kemal"
require "db"
require "pg"

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

  repo = CrystalDoc::Repo.create(url)

  "<a href='/#{repo.path}/latest'>New repository created successfully!</a>"
# rescue ex
#   "Repository failed to be created: #{ex}"
end

Kemal.run
