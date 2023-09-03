require "./crystaldoc"

db = DB.open(ENV["POSTGRES_DB"])

# Queue builders
(1..ENV["CRYSTAL_WORKERS"]?.try &.to_i || 4).each do
  spawn do
    loop do
      puts "Searching for a new job..."

      db.transaction do |tx|
        conn = tx.connection

        # Get new job from server
        jobs = CrystalDoc::DocJob.take(conn)

        if jobs.empty?
          puts "No jobs found."
          break
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

        result = builder.build

        if result
          CrystalDoc::Queries.mark_version_valid(
            conn, job.commit_id, repo["service"], repo["username"], repo["project_name"]
          )
        end
      rescue ex
        puts "Worker Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}"
        tx.try &.rollback if ex.is_a? PG::Error
      end

      sleep(15)
    end
  end
end

sleep
