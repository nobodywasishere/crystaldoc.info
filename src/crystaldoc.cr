require "kemal"

module CrystalDoc
  VERSION = "0.1.0"

  record Repository,
    url : String,
    site : String,
    user : String,
    proj : String,
    versions : Array(String)

  def self.generate_docs(repo : Repository)
    temp_folder = "#{repo.user}-#{repo.proj}"

    # clone repo from site
    unless Process.run("git", ["clone", repo.url, temp_folder]).success?
      return "Failed to clone URL: #{repo.site}"
    end
    # `git clone #{site} "#{user}-#{repo}"`

    `rm -rf "public/#{repo.site}/#{repo.user}/#{repo.proj}"`

    # Create public folder if necessary
    `mkdir -p "public/#{repo.site}/#{repo.user}/#{repo.proj}"`

    # cd into repo
    Dir.cd(temp_folder) do
      repo.versions.each do |version|
        `git checkout "#{version}"`

        # shards install to install dependencies
        # return an error if this fails
        unless Process.run("shards", ["install", "----without-development", "--skip-postinstall", "--skip-executables"]).success?
          return "Failed to install dependencies via shard"
        end

        # generate docs using crystal
        # return an error if this fails
        unless Process.run("crystal", ["doc", "--json-config-url=crystaldoc-versions.json"]).success?
          return "Failed to generate documentation with Crystal"
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
end

repositories = [
  CrystalDoc::Repository.new(
    url: "https://github.com/kemalcr/kemal",
    site: "github",
    user: "kemalcr",
    proj: "kemal",
    versions: [
      "v1.4.0",
      "v1.3.0",
      "v1.2.0",
      "v1.1.2",
      "v1.1.1",
      "v1.1.0",
      "v1.0.0"
    ]
  )
]

get "/" do
  "CrystalDoc.info - Crystal Shard Documentation"
end

GIT_WEBSITES = [
  {
    abbrv: "github",
    url: "https://github.com"
  },
  {
    abbrv: "gitlab",
    url: "https://gitlab.com"
  }
]

GIT_WEBSITES.each do |site|
  get "/#{site[:abbrv]}/:user/:proj" do |env|
    proj = env.params.url["proj"]
    user = env.params.url["user"]

    repo = repositories.select { |repo|
      repo.site == site[:abbrv] &&
      repo.user == user &&
      repo.proj == proj
    }.first

    unless File.exists?("public/#{site[:abbrv]}/#{repo.user}/#{repo.proj}/#{repo.versions.first}")
      puts CrystalDoc.generate_docs(repo)
    end

    env.redirect "/#{site[:abbrv]}/#{repo.user}/#{repo.proj}/latest"
  end

  get "/#{site[:abbrv]}/:user/:proj/latest" do |env|
    proj = env.params.url["proj"]
    user = env.params.url["user"]

    repo = repositories.select { |repo|
      repo.site == site[:abbrv] &&
      repo.user == user &&
      repo.proj == proj
    }.first

    env.redirect "/#{site[:abbrv]}/#{repo.user}/#{repo.proj}/#{repo.versions.first}/index.html"
  end

  # Need to provide versions json at every possible path/
  # Don't know if this only catches those that end with `crystaldoc-versions.json`
  # but it works for now/
  get "/#{site[:abbrv]}/:user/:proj/*all/crystaldoc-versions.json" do |env|
    proj = env.params.url["proj"]
    user = env.params.url["user"]

    repo = repositories.select { |repo|
      repo.site == site[:abbrv] &&
      repo.user == user &&
      repo.proj == proj
    }.first

    CrystalDoc.versions_to_json(repo)
  end
end

Kemal.run
