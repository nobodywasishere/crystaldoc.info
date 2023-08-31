require "kemal"

class CrystalDoc::DocsHandler < Kemal::Handler
  def call(context)
    path = context.request.path
    if /(?:\/~?[a-zA-Z0-9\.\-_]+){4,}\/.*\.html/.match(path)
      repo = parse_path(path)
      source_url = nil

      db = DB.open(ENV["POSTGRES_DB"])

      # make sure repo exists
      log "Checking if repo exists..."
      unless CrystalDoc::Queries.repo_exists(db, repo["service"], repo["username"], repo["project_name"])
        puts "Repo doesn't exist: #{repo.values.join("/")}"

        call_next(context)
        return
      end
      log "Succcess."

      log "Getting the repo id..."
      repo_id = db.query_one(<<-SQL, repo["service"], repo["username"], repo["project_name"], as: Int32)
        SELECT repo.id
        FROM crystal_doc.repo
        WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3
      SQL
      log "Success."

      # make sure repo version exists
      log "Checking if repo version exists..."
      unless CrystalDoc::Queries.repo_version_exists(db, repo_id, repo["version"])
        puts "Repo version doesn't exist: #{repo.values.join("/")}"

        call_next(context)
        return
      end
      log "Succcess."

      # check if checked in the past day
      log "Checking last update time..."
      last_checked_rs = db.query(<<-SQL, repo_id)
        SELECT repo_status.last_checked
        FROM crystal_doc.repo_status
        WHERE repo_status.repo_id = $1
      SQL

      last_checked = Time::UNIX_EPOCH
      last_checked_rs.each do
        last_checked = last_checked_rs.read(Time)
      end

      if (Time.utc - last_checked).days == 0 && File.exists?("public/#{repo.values.join("/")}/index.html")
        puts "Repo checked within past day: #{repo.values.join("/")}"
        puts "Last checked: #{last_checked}"

        call_next(context)
        return
      end
      log "Succcess."

      log "Checking if version is nightly..."
      nightly = db.query_one(<<-SQL, repo_id, repo["version"], as: Bool)
        SELECT repo_version.nightly
        FROM crystal_doc.repo_version
        WHERE repo_version.repo_id = $1 AND repo_version.commit_id = $2
      SQL
      log "Succcess."

      # get the source url
      log "Getting the source url..."
      source_url = db.query_one(<<-SQL, repo_id, as: String)
        SELECT repo.source_url
        FROM crystal_doc.repo
        WHERE repo.id = $1
      SQL
      log "Succcess."

      log "Searching for new versions..."
      CrystalDoc::Queries.refresh_repo_versions(db, repo_id)
      log "Succcess."

      # update the repo status time
      log "Updating the repo last checked time..."
      CrystalDoc::Queries.upsert_repo_status(db, repo_id)
      log "Succcess."

      if !File.exists?("public/#{repo.values.join("/")}/index.html") || nightly
        puts "Building docs for #{repo.values.join("/")} (#{source_url})"

        builder = CrystalDoc::DocsBuilder.new(
          source_url, repo["service"], repo["username"], repo["project_name"], repo["version"]
        )
        builder.build

        log "Succcess."
      end
    end

    call_next(context)
  rescue ex
    puts "DocsHandler Exception: #{ex}"
    puts "  #{ex.backtrace.join("\n  ")}"
  ensure
    db.try &.close
  end

  private def parse_path(path) : Hash(String, String)
    split_path = path.split("/")

    {
      "service"      => split_path[1],
      "username"     => split_path[2],
      "project_name" => split_path[3],
      "version"      => split_path[4],
    }
  end

  private def log(msg)
    if true
      puts msg
    end
  end
end
