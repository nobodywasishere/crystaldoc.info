require "./crystaldoc"

(1..ENV["CRYSTAL_WORKERS"]?.try &.to_i || 4).each do
  spawn do
    loop do
      DB.open(ENV["POSTGRES_DB"]) do |db|
        db.transaction do |tx|
          puts "Searching for a new job..."

          conn = tx.connection

          # Get new job from server
          jobs = CrystalDoc::DocJob.take(conn)

          if jobs.empty?
            puts "No jobs found."
            sleep(10)
            next
          else
            job = jobs.first
          end

          puts "Building docs for #{job.inspect}"

          # execute doc generation
          repo = CrystalDoc::Queries.repo_from_source(conn, job.source_url).first

          builder = CrystalDoc::Builder.new(
            job.source_url,
            repo["service"],
            repo["username"],
            repo["project_name"],
            job.commit_id
          )

          builder.build
        end
      rescue ex
        puts "Worker Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}"
        sleep 10
      end
    end
  end
end

sleep
