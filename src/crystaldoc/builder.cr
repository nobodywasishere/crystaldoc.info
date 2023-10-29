require "html"

class CrystalDoc::Builder
  Log = ::Log.for(self)

  getter log = Log
  getter idx : Int32

  def initialize(@idx)
  end

  def search_for_jobs(db : Queriable)
    loop do
      Log.info { "#{idx}: Searching for a new job" }
      db.transaction do |tx|
        conn = tx.connection

        jobs = CrystalDoc::DocJob.take(conn)

        if jobs.empty?
          Log.info { "#{idx}: No jobs found." }
          sleep(50)
          break
        else
          job = jobs.first
        end

        Log.info { "#{idx}: Building docs for #{job.inspect}" }

        repo = CrystalDoc::Queries.repo_from_source(conn, job.source_url).first

        result = build(repo, job.commit_id)

        if result
          CrystalDoc::Queries.mark_version_valid(
            conn, job.commit_id, repo.service, repo.username, repo.project_name
          )
        else
          CrystalDoc::Queries.mark_version_invalid(
            conn, job.commit_id, repo.service, repo.username, repo.project_name
          )
        end
      rescue ex
        Log.error { "#{idx}: Build Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}" }
        tx.try &.rollback if ex.is_a? PG::Error

        unless job.nil? || repo.nil?
          CrystalDoc::Queries.mark_version_invalid(
            REPO_DB, job.commit_id, repo.service, repo.username, repo.project_name
          )
        end
      end

      sleep(10)
    end
  end

  def build(repo : Repo, version : String) : Bool
    case repo.build_type
    when "git"
      build_git(repo, version)
    when "crystal"
      build_crystal(repo, version)
    when "fossil"
      build_fossil(repo, version)
    else
      raise "Unknown build type '#{repo.build_type}'"
    end
  end

  def build_git(repo : Repo, version : String) : Bool
    build_dir = Path["#{repo.service}-#{repo.username}-#{repo.project_name}-#{version}"].expand.to_s
    repo_output_dir = Path["public#{repo.path}/#{version}"].expand.to_s
    Log.info { "#{idx}: Repo output dir: #{repo_output_dir}" }

    execute("rm", ["-rf", build_dir], current_dir)

    unless git_clone_repo(repo.source_url, build_dir).success?
      Log.error { "#{idx}: Failed to clone URL: #{repo.source_url}" }
      raise "Failed to clone URL: #{repo.source_url}"
    end

    unless git_checkout(version, build_dir).success?
      Log.error { "#{idx}: Failed to checkout version #{version}" }
      raise "Failed to checkout version #{version}"
    end

    Log.info { "#{idx}: Removing existing docs folder..." }
    execute("rm", ["-rf", "docs"], build_dir)

    unless shards_install(build_dir).success?
      Log.error { "#{idx}: Failed to install shards" }
      raise "Failed to install shards"
    end

    if execute("test", ["-f", "readme.md"], build_dir).success? && !execute("test", ["-f", "README.md"], build_dir).success?
      Log.info { "#{idx}: Moving readme" }
      execute("mv", ["readme.md", "README.md"], build_dir)
    end

    unless crystal_doc(repo.path, version, build_dir).success?
      Log.error { "#{idx}: Failed to build docs" }
      raise "Failed to build docs"
    end

    post_process(build_dir, repo, version)

    # make destination folder if necessary
    Log.info { "#{idx}: Deleting destination folder..." }
    execute("rm", ["-rf", repo_output_dir], current_dir)

    # make destination folder if necessary
    Log.info { "#{idx}: Creating destination folder..." }
    unless execute("mkdir", ["-p", Path["public#{repo.path}"].expand.to_s], current_dir).success?
      Log.error { "#{idx}: Failed to create destination folder" }
      raise "Failed to create destination folder"
    end

    # move ./docs folder to destination folder
    Log.info { "#{idx}: Copying docs to destination folder..." }
    unless execute("mv", ["docs", repo_output_dir], build_dir).success?
      Log.error { "#{idx}: Failed to copy docs to destination folder #{repo_output_dir}" }
      raise "Failed to copy docs to destination folder #{repo_output_dir}"
    end

    true
  rescue ex
    Log.error { "#{idx}: Builder Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}" }

    unless repo_output_dir.nil?
      # remove destination folder
      execute("rm", ["-rf", repo_output_dir], current_dir)

      # re-create destination folder
      execute("mkdir", ["-p", repo_output_dir], current_dir)

      # render build failure template
      File.write "#{repo_output_dir}/index.html",
        CrystalDoc::Views::BuildFailureTemplate.new(repo.source_url)
    end

    false
  ensure
    unless build_dir.nil?
      # ensure removal of temp folder
      execute("rm", ["-rf", build_dir], current_dir)
    end
  end

  def build_crystal(repo : Repo, version : String) : Bool
    build_dir = Path["#{repo.service}-#{repo.username}-#{repo.project_name}-#{version}"].expand.to_s
    repo_output_dir = Path["public#{repo.path}/#{version}"].expand.to_s
    Log.info { "#{idx}: Repo output dir: #{repo_output_dir}" }

    execute("rm", ["-rf", build_dir], current_dir)

    unless git_clone_repo(repo.source_url, build_dir).success?
      Log.error { "#{idx}: Failed to clone URL: #{repo.source_url}" }
      raise "Failed to clone URL: #{repo.source_url}"
    end

    unless git_checkout(version, build_dir).success?
      Log.error { "#{idx}: Failed to checkout version #{version}" }
      raise "Failed to checkout version #{version}"
    end

    Log.info { "#{idx}: Removing existing docs folder..." }
    execute("rm", ["-rf", "docs"], build_dir)

    if execute("test", ["-f", "readme.md"], build_dir).success? && !execute("test", ["-f", "README.md"], build_dir).success?
      Log.info { "#{idx}: Moving readme" }
      execute("mv", ["readme.md", "README.md"], build_dir)
    end

    ENV["DOCS_OPTIONS"] = "--json-config-url=#{repo.path}/versions.json --source-refname=#{version} --project-version=#{version}"
    unless execute("make", ["docs"], build_dir).success?
      Log.error { "#{idx}: Failed to build docs" }
      raise "Failed to build docs"
    end

    post_process(build_dir, repo, version)

    # make destination folder if necessary
    Log.info { "#{idx}: Deleting destination folder..." }
    execute("rm", ["-rf", repo_output_dir], current_dir)

    # make destination folder if necessary
    Log.info { "#{idx}: Creating destination folder..." }
    unless execute("mkdir", ["-p", Path["public#{repo.path}"].expand.to_s], current_dir).success?
      Log.error { "#{idx}: Failed to create destination folder" }
      raise "Failed to create destination folder"
    end

    # move ./docs folder to destination folder
    Log.info { "#{idx}: Copying docs to destination folder..." }
    unless execute("mv", ["docs", repo_output_dir], build_dir).success?
      Log.error { "#{idx}: Failed to copy docs to destination folder #{repo_output_dir}" }
      raise "Failed to copy docs to destination folder #{repo_output_dir}"
    end

    true
  rescue ex
    Log.error { "#{idx}: Builder Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}" }

    unless repo_output_dir.nil?
      # remove destination folder
      execute("rm", ["-rf", repo_output_dir], current_dir)

      # re-create destination folder
      execute("mkdir", ["-p", repo_output_dir], current_dir)

      # render build failure template
      File.write "#{repo_output_dir}/index.html",
        CrystalDoc::Views::BuildFailureTemplate.new(repo.source_url)
    end

    false
  ensure
    unless build_dir.nil?
      # ensure removal of temp folder
      execute("rm", ["-rf", build_dir], current_dir)
    end
  end

  def build_fossil(repo : Repo, version : String) : Bool
    build_dir = Path["#{repo.service}-#{repo.username}-#{repo.project_name}-#{version}"].expand.to_s
    fossil_file = build_dir + ".fossil"
    repo_output_dir = Path["public#{repo.path}/#{version}"].expand.to_s
    Log.info { "#{idx}: Repo output dir: #{repo_output_dir}" }

    execute("rm", ["-rf", build_dir], current_dir)

    execute("rm", ["-rf", fossil_file], current_dir)

    Dir.mkdir_p(build_dir)

    unless fossil_clone(repo.source_url, fossil_file).success?
      Log.error { "#{idx}: Failed to clone repo" }
      raise "Failed to clone repo"
    end

    unless fossil_open(version, fossil_file, build_dir).success?
      Log.error { "#{idx}: Failed to open version" }
      raise "Failed to open version"
    end

    Log.info { "#{idx}: Removing existing docs folder..." }
    execute("rm", ["-rf", "docs"], build_dir)

    unless shards_install(build_dir).success?
      Log.error { "#{idx}: Failed to install shards" }
      raise "Failed to install shards"
    end

    if execute("test", ["-f", "readme.md"], build_dir).success? && !execute("test", ["-f", "README.md"], build_dir).success?
      Log.info { "#{idx}: Moving readme" }
      execute("mv", ["readme.md", "README.md"], build_dir)
    end

    unless crystal_doc(repo.path, version, build_dir).success?
      Log.error { "#{idx}: Failed to build docs" }
      raise "Failed to build docs"
    end

    post_process(build_dir, repo, version)

    # make destination folder if necessary
    Log.info { "#{idx}: Deleting destination folder..." }
    execute("rm", ["-rf", repo_output_dir], current_dir)

    # make destination folder if necessary
    Log.info { "#{idx}: Creating destination folder..." }
    unless execute("mkdir", ["-p", Path["public#{repo.path}"].expand.to_s], current_dir).success?
      Log.error { "#{idx}: Failed to create destination folder" }
      raise "Failed to create destination folder"
    end

    # move ./docs folder to destination folder
    Log.info { "#{idx}: Copying docs to destination folder..." }
    unless execute("mv", ["docs", repo_output_dir], build_dir).success?
      Log.error { "#{idx}: Failed to copy docs to destination folder #{repo_output_dir}" }
      raise "Failed to copy docs to destination folder #{repo_output_dir}"
    end

    true
  rescue ex
    Log.error { "#{idx}: Builder Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}" }

    unless repo_output_dir.nil?
      # remove destination folder
      execute("rm", ["-rf", repo_output_dir], current_dir)

      # re-create destination folder
      execute("mkdir", ["-p", repo_output_dir], current_dir)

      # render build failure template
      File.write "#{repo_output_dir}/index.html",
        CrystalDoc::Views::BuildFailureTemplate.new(repo.source_url)
    end

    false
  ensure
    unless build_dir.nil?
      # ensure removal of temp folder
      execute("rm", ["-rf", build_dir], current_dir)
    end

    unless fossil_file.nil?
      execute("rm", ["-rf", fossil_file], current_dir)
    end
  end

  private def current_dir : String
    Path["."].expand.to_s
  end

  private def git_clone_repo(source_url : String, folder : String) : Process::Status
    Log.info { "#{idx}: Cloning repo..." }

    stdout = IO::Memory.new
    stderr = IO::Memory.new

    result = Process.run(
      "git",
      ["clone", source_url, folder],
      env: {"GIT_TERMINAL_PROMPT" => "0", "POSTGRES_DB" => ""},
      output: stdout, error: stderr
    )

    Log.info { "#{idx}: git_clone_repo: " + stdout.to_s } unless stdout.to_s.empty?
    Log.error { "#{idx}: git_clone_repo: " + stderr.to_s } unless stderr.to_s.empty? || result.success?

    result
  end

  private def git_checkout(version : String, folder : String) : Process::Status
    Log.info { "#{idx}: Checking out version #{version}..." }

    stdout = IO::Memory.new
    stderr = IO::Memory.new

    result = Process.run(
      "git",
      ["checkout", "--force", version],
      env: {"GIT_TERMINAL_PROMPT" => "0", "POSTGRES_DB" => ""},
      chdir: folder,
      output: stdout, error: stderr
    )

    Log.info { "#{idx}: git_checkout: " + stdout.to_s } unless stdout.to_s.empty?
    Log.error { "#{idx}: git_checkout: " + stderr.to_s } unless stderr.to_s.empty? || result.success?

    result
  end

  private def fossil_clone(source_url : String, filename : String) : Process::Status
    Log.info { "#{idx}: Cloning out fossil repo #{source_url}..." }

    stdout = IO::Memory.new
    stderr = IO::Memory.new

    result = Process.run(
      "fossil",
      [
        "clone",
        source_url,
        "--no-open",
        filename,
      ],
      env: {"POSTGRES_DB" => ""},
      output: stdout, error: stderr
    )

    Log.info { "#{idx}: fossil_clone: " + stdout.to_s } unless stdout.to_s.empty?
    Log.error { "#{idx}: fossil_clone: " + stderr.to_s } unless stderr.to_s.empty? || result.success?

    result
  end

  private def fossil_open(version : String, fossil_file : String, folder : String) : Process::Status
    Log.info { "#{idx}: Open fossil version #{version}..." }

    stdout = IO::Memory.new
    stderr = IO::Memory.new

    result = Process.run(
      "fossil",
      [
        "open",
        fossil_file,
        version,
      ],
      env: {"POSTGRES_DB" => ""},
      chdir: folder,
      output: stdout, error: stderr
    )

    Log.info { "#{idx}: fossil_open: " + stdout.to_s } unless stdout.to_s.empty?
    Log.error { "#{idx}: fossil_open: " + stderr.to_s } unless stderr.to_s.empty? || result.success?

    result
  end

  private def shards_install(folder : String) : Process::Status
    Log.info { "#{idx}: Running shards install..." }

    Dir.mkdir_p("#{folder}/lib")

    safe_execute(
      "shards",
      [
        "install",
        "--skip-postinstall",
        "--skip-executables",
      ],
      folder: folder,
      # Need to be able to create the shard.lock if it doesn't exist
      rw_dirs: [folder],
      ro_dirs: [Path[folder].parent.to_s],
      networking: true
    )
  end

  private def crystal_doc(repo_path : String, version : String, folder : String) : Process::Status
    Log.info { "#{idx}: Building docs..." }

    Dir.mkdir("#{folder}/docs")

    safe_execute(
      "crystal",
      [
        "doc",
        "--json-config-url=#{repo_path}/versions.json",
        "--source-refname=#{version}",
        "--project-version=#{version}",
      ],
      folder: folder,
      rw_dirs: ["#{folder}/docs"],
      ro_dirs: [folder],
      networking: false
    )
  end

  private def execute(cmd : String, args : Array(String), folder : String) : Process::Status
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    Log.info { "#{idx}: Executing: #{cmd} #{args.join(" ")}" }

    result = Process.run(
      cmd, args,
      chdir: folder,
      env: {"POSTGRES_DB" => ""},
      output: stdout, error: stderr
    )

    Log.info { "#{idx}: execute #{cmd}: " + stdout.to_s } unless stdout.to_s.empty?
    Log.error { "#{idx}: execute #{cmd}: " + stderr.to_s } unless stderr.to_s.empty? || result.success?

    result
  end

  def safe_execute(cmd : String, args : Array(String), folder : String,
                   rw_dirs : Array(String), ro_dirs : Array(String),
                   networking : Bool = false) : Process::Status
    fj_args = [
      "--noprofile",
      "--restrict-namespaces",
      "--rlimit-as=3g",
      "--timeout=00:15:00",
    ]

    fj_args += ro_dirs.map { |d| "--read-only=#{d}" }
    fj_args += rw_dirs.map { |d| "--read-write=#{d}" }

    fj_args += ["--net=none"] unless networking

    fj_args += [cmd, *args]

    stdout = IO::Memory.new
    stderr = IO::Memory.new

    Log.info { "#{idx}: Safe executing: firejail #{fj_args.join(" ")}" }

    result = Process.run("firejail", fj_args,
      chdir: folder,
      env: {"POSTGRES_DB" => ""},
      output: stdout, error: stderr
    )

    Log.info { "#{idx}: safe execute #{cmd}: " + stdout.to_s } unless stdout.to_s.empty?
    Log.error { "#{idx}: safe execute #{cmd}: " + stderr.to_s } unless stderr.to_s.empty? || result.success?

    result
  end

  private def post_process(folder : String, repo : Repo, version : String) : Nil
    Log.info { "#{idx}: Post processing..." }

    CrystalDoc::Html.post_process("#{folder}/docs") do |html, _|
      sidebar = html.css(".sidebar").first
      sidebar["style"] = "display: flex; flex-direction: column; padding-top: 8px"

      html.head!.inner_html += <<-HTML
        <script class="crystaldoc-post-process" data-goatcounter="https://crystaldoc-info.goatcounter.com/count" async src="//gc.zgo.at/count.js"></script>
        <noscript class="crystaldoc-post-process">
          <img src="https://crystaldoc-info.goatcounter.com/count?p=#{repo.path}/#{version}">
        </noscript>

        <link class="crystaldoc-post-process" rel="apple-touch-icon" sizes="57x57" href="/assets/apple-icon-57x57.png">
        <link class="crystaldoc-post-process" rel="apple-touch-icon" sizes="60x60" href="/assets/apple-icon-60x60.png">
        <link class="crystaldoc-post-process" rel="apple-touch-icon" sizes="72x72" href="/assets/apple-icon-72x72.png">
        <link class="crystaldoc-post-process" rel="apple-touch-icon" sizes="76x76" href="/assets/apple-icon-76x76.png">
        <link class="crystaldoc-post-process" rel="apple-touch-icon" sizes="114x114" href="/assets/apple-icon-114x114.png">
        <link class="crystaldoc-post-process" rel="apple-touch-icon" sizes="120x120" href="/assets/apple-icon-120x120.png">
        <link class="crystaldoc-post-process" rel="apple-touch-icon" sizes="144x144" href="/assets/apple-icon-144x144.png">
        <link class="crystaldoc-post-process" rel="apple-touch-icon" sizes="152x152" href="/assets/apple-icon-152x152.png">
        <link class="crystaldoc-post-process" rel="apple-touch-icon" sizes="180x180" href="/assets/apple-icon-180x180.png">
        <link class="crystaldoc-post-process" rel="icon" type="image/png" sizes="192x192" href="/assets/android-icon-192x192.png">
        <link class="crystaldoc-post-process" rel="icon" type="image/png" sizes="32x32" href="/assets/favicon-32x32.png">
        <link class="crystaldoc-post-process" rel="icon" type="image/png" sizes="96x96" href="/assets/favicon-96x96.png">
        <link class="crystaldoc-post-process" rel="icon" type="image/png" sizes="16x16" href="/assets/favicon-16x16.png">
        <link class="crystaldoc-post-process" rel="manifest" href="/assets/manifest.json">
      HTML

      sidebar.inner_html += <<-HTML
        <div class="crystaldoc-post-process" style="margin-top: auto; padding: 27px 0 0 30px;">
          <small>
            Built with Crystal #{Crystal::VERSION}<br>#{Time.utc}
          </small>
        </div>
      HTML

      sidebar_header = html.css(".sidebar-header").first
      sidebar_search_box = sidebar_header.css(".search-box").first
      sidebar_project_summary = sidebar_header.css(".project-summary").first

      shards_info_link = <<-HTML
        <a style="margin: 0 10px 0 0" href='https://shards.info#{repo.path}'>
          Shards.info
        </a>
      HTML

      sidebar_header.inner_html = <<-HTML + sidebar_search_box.to_html + sidebar_project_summary.to_html
        <div class="crystaldoc-info-header crystaldoc-post-process" style="padding: 9px 15px 9px 30px">
          <h1 class="project-name" style="margin: 8px 0 8px 0; color: #F8F4FD">
            <a href="/">CrystalDoc.info</a>
          </h1>
          <div style="margin: 16px 0 0 0">
            <a style="margin: 0 12px 0 0" href="#{repo.source_url}">Source code</a>
            #{shards_info_link}
          </div>
        </div>
      HTML
    end
  end
end
