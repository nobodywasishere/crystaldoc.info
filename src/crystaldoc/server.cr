require "kemal"

get "/" do
  render "src/views/main.ecr", "src/views/layouts/layout.ecr"
end

get "/:site/:user/:proj" do |env|
  repo = CrystalDoc::Repository.from_kemal_env(env)

  unless repo.versions.size > 0 && File.exists?("public/#{repo.site}/#{repo.user}/#{repo.proj}/#{repo.versions.first}")
    puts CrystalDoc::Worker.generate_docs(repo)
  end

  env.redirect "/#{repo.site}/#{repo.user}/#{repo.proj}/latest"
end

get "/:site/:user/:proj/latest" do |env|
  repo = CrystalDoc::Repository.from_kemal_env(env)

  env.redirect "/#{repo.site}/#{repo.user}/#{repo.proj}/#{repo.versions.first}/index.html"
end

get "/:site/:user/:proj/versions.json" do |env|
  repo = CrystalDoc::Repository.from_kemal_env(env)

  repo.versions_to_json
end

Kemal.run
