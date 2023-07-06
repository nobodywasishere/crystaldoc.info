require "kemal"

module CrystalDoc
  VERSION = "0.1.0"

  def self.generate_docs(url : String, site : String, user : String, repo : String)
    # clone repo from site
    unless Process.run("git", ["clone", url, "#{user}-#{repo}"]).success?
      return "Failed to clone URL: #{site}"
    end
    # `git clone #{site} "#{user}-#{repo}"`

    # cd into repo
    Dir.cd("#{user}-#{repo}") do
      # shards install to install dependencies
      # return an error if this fails
      unless Process.run("shards", ["install", "----without-development", "--skip-postinstall", "--skip-executables"]).success?
        return "Failed to install dependencies via shard"
      end

      # generate docs using crystal
      # return an error if this fails
      unless Process.run("crystal", ["doc"]).success?
        return "Failed to generate documentation with Crystal"
      end
    end

    `rm -rf "public/#{site}/#{user}/#{repo}"`

    # Create public folder if necessary
    `mkdir -p "public/#{site}/#{user}"`

    # copy docs to `/public/:site/:repo/:user` folder
    `mv "#{user}-#{repo}/docs" "public/#{site}/#{user}/#{repo}"`

    "Generated #{site} documentation"
  ensure
    `rm -rf "#{user}-#{repo}"`
  end
end

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
  get "/#{site[:abbrv]}/:user/:repo" do |env|
    repo = env.params.url["repo"]
    user = env.params.url["user"]

    unless File.exists?("public/#{site[:abbrv]}/#{user}/#{repo}/index.html")
      puts CrystalDoc.generate_docs(url: "#{site[:url]}/#{user}/#{repo}", site: site[:abbrv], user: user, repo: repo)
    end

    File.read("public/#{site[:abbrv]}/#{user}/#{repo}/index.html")
  end
end

Kemal.run
