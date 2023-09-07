require "./crystaldoc"

Dir.mkdir_p "./logs"
log_file = File.new("./logs/builder.log", "a+")

Log.setup(:info, Log::IOBackend.new(log_file))

REPO_DB = DB.open(ENV["POSTGRES_DB"])

# Queue builders
(1..ENV["CRYSTAL_WORKERS"]?.try &.to_i || 4).each do |idx|
  spawn do
    log = ::Log.for("builder").for("#{idx}")

    log.info { "#{idx}: Starting crystaldoc builder" }

    loop do
      log.info { "#{idx}: Searching for a new job..." }

      REPO_DB.transaction do |tx|
        conn = tx.connection

        # Get new job from server
        jobs = CrystalDoc::DocJob.take(conn)

        if jobs.empty?
          log.info { "#{idx}: No jobs found." }
          sleep(50)
          break
        else
          job = jobs.first
        end

        log.info { "#{idx}: Building docs for #{job.inspect}" }

        # execute doc generation
        repo = CrystalDoc::Queries.repo_from_source(conn, job.source_url).first

        builder = CrystalDoc::Builder.new(
          job.source_url,
          repo.service,
          repo.username,
          repo.project_name,
          job.commit_id
        )

        result = builder.build

        if result
          CrystalDoc::Queries.mark_version_valid(
            conn, job.commit_id, repo.service, repo.username, repo.project_name
          )
        end
      rescue ex
        log.error { "#{idx}: Worker Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}" }
        tx.try &.rollback if ex.is_a? PG::Error
      end

      sleep(10)
    end
  end
end

sleep
