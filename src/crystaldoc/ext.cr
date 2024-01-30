#
# Methods for getting data from external services.
#
module CrystalDoc::Ext
  Log = ::Log.for("ext")

  record Data, stars : Int32, fork : Bool do
    include ::DB::Serializable
    include ::DB::Serializable::NonStrict
  end

  def self.get_data_for(repo : Repo) : Data?
    get_data_for(repo.service, repo.username, repo.project_name)
  end

  def self.get_data_for(service, username, project_name)
    case service
    when "github"
      get_github_data_for(username, project_name)
    when "gitlab"
      get_gitlab_data_for(username, project_name)
    else
      nil
    end
  end

  def self.get_github_data_for(user : String, project : String) : Data?
    headers = HTTP::Headers.new
    headers["Accept"] = "application/vnd.github+json"
    headers["X-Github-Api-Version"] = "2022-11-28"
    headers["User-Agent"] = "CrystalDoc-info"
    headers["Authorization"] = "Bearer #{::Config.github_api_key}"

    url = URI.new("https", "api.github.com", path: "/repos/#{user}/#{project}")

    response = HTTP::Client.get(url: url, headers: headers)

    Log.info { "github data (#{response.status_code}): #{response.body}" }

    return unless response.success?

    pull = JSON::PullParser.new(response.body)

    stars = nil
    fork = false

    pull.read_object do |key|
      case key
      when "stargazers_count"
        stars = pull.read_int.to_i32
      when "fork"
        fork = pull.read_bool
      else
        pull.skip
      end
    end

    if stars
      Data.new(stars, fork)
    end
  end

  def self.get_gitlab_data_for(user : String, project : String) : Data?
    headers = HTTP::Headers.new
    headers["Accept"] = "application/json"
    headers["User-Agent"] = "CrystalDoc-info"
    headers["PRIVATE-TOKEN"] = ::Config.gitlab_api_key

    url = URI.new("https", "gitlab.com", path: "/api/v4/projects/#{user}%2F#{project}")

    response = HTTP::Client.get(url: url, headers: headers)

    Log.info { "gitlab data (#{response.status_code}): #{response.body}" }

    return unless response.success?

    pull = JSON::PullParser.new(response.body)

    stars = nil
    fork = false

    pull.read_object do |key|
      case key
      when "star_count"
        stars = pull.read_int.to_i32
      when "forked_from_project"
        fork = true
      else
        pull.skip
      end
    end

    if stars
      Data.new(stars, fork)
    end
  end
end
