require "kemal"

class CrystalDoc::StatsHandler < Kemal::Handler
  def call(context)
    path = context.request.path
    if /(?:\/~?[a-zA-Z0-9\.\-_]+){4,}\/.*\.html/.match(path)
      repo = parse_path(path)
      puts "Incrementing stats count for #{repo.values.join("/")}"

      DB.open(ENV["POSTGRES_DB"]) do |db|
        CrystalDoc::Queries.increment_repo_stats(db, repo["service"], repo["username"], repo["project_name"])
      end
    end

    call_next(context)
  end

  private def parse_path(path) : Hash(String, String)
    split_path = path.split("/")

    {
      "service"      => split_path[1],
      "username"     => split_path[2],
      "project_name" => split_path[3],
    }
  end
end
