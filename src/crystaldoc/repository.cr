module CrystalDoc
  GIT_WEBSITES = {
    "github" => "https://github.com",
    "gitlab" => "https://gitlab.com"
  }

  class Repository
    getter url : String
    getter site : String
    getter user : String
    getter proj : String
    getter versions : Set(String)

    def initialize(
      @url : String, @site : String,
      @user : String, @proj : String,
      @versions : Set(String)
    )
    end

    def self.from_kemal_env(env)
      site = env.params.url["site"]
      proj = env.params.url["proj"]
      user = env.params.url["user"]

      repo = CrystalDoc.repositories.select { |repo|
        repo.site == site &&
        repo.user == user &&
        repo.proj == proj
      }

      if repo.empty?
        repo = CrystalDoc::Repository.new(
          url: "#{CrystalDoc::GIT_WEBSITES[site]}/#{user}/#{proj}",
          site: site,
          user: user,
          proj: proj,
          versions: Set.new [] of String
        )
        CrystalDoc.repositories << repo
      else
        repo = repo.first
      end

      repo
    end

    def versions_to_json
      str = "{\"versions\":["
      str += versions.map do |version|
        "{\"name\": \"#{version}\", \"url\": \"/#{site}/#{user}/#{proj}/#{version}/index.html\"}"
      end.join(",")
      str += "]}"
    end
  end

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
        "v1.0.0",
      }
    ),
  ]
end
