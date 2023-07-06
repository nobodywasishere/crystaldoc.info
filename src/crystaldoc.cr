require "kemal"

module CrystalDoc
  VERSION = "0.1.0"

  GIT_WEBSITES = {
    "github" => "https://github.com",
    "gitlab" => "https://gitlab.com"
  }

  class_property repositories
  @@repositories = [
    CrystalDoc::Repository.new(
      url: "https://github.com/kemalcr/kemal",
      site: "github",
      user: "kemalcr",
      proj: "kemal",
      versions: Set{
        "v1.4.0",
        "v1.3.0",
        "v1.2.0",
        "v1.1.2",
        "v1.1.1",
        "v1.1.0",
        "v1.0.0"
      }
    )
  ]

  record Repository,
    url : String,
    site : String,
    user : String,
    proj : String,
    versions : Set(String)

  def self.generate_docs(repo : Repository)
    temp_folder = "#{repo.user}-#{repo.proj}"

    # clone repo from site
    unless Process.run("git", ["clone", repo.url, temp_folder]).success?
      raise "Failed to clone URL: #{repo.site}"
    end
    # `git clone #{site} "#{user}-#{repo}"`

    `rm -rf "public/#{repo.site}/#{repo.user}/#{repo.proj}"`

    # Create public folder if necessary
    `mkdir -p "public/#{repo.site}/#{repo.user}/#{repo.proj}"`

    # cd into repo
    Dir.cd(temp_folder) do
      if repo.versions.empty?
        repo.versions.add(`git branch --show-current`.strip)
        repo.versions.add(`git describe --tags --abbrev=0`.strip)
      end

      repo.versions.each do |version|
        `git checkout "#{version}"`

        # shards install to install dependencies
        # return an error if this fails
        unless Process.run("shards", ["install", "----without-development", "--skip-postinstall", "--skip-executables"]).success?
          raise "Failed to install dependencies via shard"
        end

        # generate docs using crystal
        # return an error if this fails
        unless Process.run("crystal", ["doc", "--json-config-url=crystaldoc-versions.json"]).success?
          raise "Failed to generate documentation with Crystal"
        end

        # copy docs to `/public/:site/:repo/:user` folder
        `mv "docs" "../public/#{repo.site}/#{repo.user}/#{repo.proj}/#{version}"`
      end
    end

    "Generated #{repo.site} documentation"
  ensure
    `rm -rf "#{temp_folder}"`
  end

  def self.versions_to_json(repo : Repository)
    str = "{\"latest\": \"#{repo.versions.first}\","
    str += "\"versions\":["
    str += repo.versions.map do |version|
      "{\"name\": \"#{version}\", \"url\": \"/#{repo.site}/#{repo.user}/#{repo.proj}/#{version}/index.html\"}"
    end.join(",")
    str += "]}"
  end

  def self.env_to_repo(env)
    site = env.params.url["site"]
    proj = env.params.url["proj"]
    user = env.params.url["user"]

    repo = @@repositories.select { |repo|
      repo.site == site &&
      repo.user == user &&
      repo.proj == proj
    }

    if repo.empty?
      repo = CrystalDoc::Repository.new(
        url: "#{GIT_WEBSITES[site]}/#{user}/#{proj}",
        site: site,
        user: user,
        proj: proj,
        versions: Set.new [] of String
      )
      @@repositories << repo
    else
      repo = repo.first
    end

    repo
  end
end

get "/" do
  "CrystalDoc.info - Crystal Shard Documentation"
end

get "/:site/:user/:proj" do |env|
  repo = CrystalDoc.env_to_repo(env)

  unless repo.versions.size > 0 && File.exists?("public/#{repo.site}/#{repo.user}/#{repo.proj}/#{repo.versions.first}")
    puts CrystalDoc.generate_docs(repo)
  end

  env.redirect "/#{repo.site}/#{repo.user}/#{repo.proj}/latest"
end

get "/:site/:user/:proj/latest" do |env|
  repo = CrystalDoc.env_to_repo(env)

  env.redirect "/#{repo.site}/#{repo.user}/#{repo.proj}/#{repo.versions.first}/index.html"
end

# Need to provide versions json at every possible path/
# Don't know if this only catches those that end with `crystaldoc-versions.json`
# but it works for now/
get "/:site/:user/:proj/*all/crystaldoc-versions.json" do |env|
  repo = CrystalDoc.env_to_repo(env)

  CrystalDoc.versions_to_json(repo)
end

Kemal.run
