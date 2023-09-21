require "html"

class CrystalDoc::Builder
  Log = ::Log.for(self)

  getter source_url : String
  getter service : String
  getter username : String
  getter project_name : String
  getter version : String

  def initialize(@source_url, @service, @username, @project_name, @version)
  end

  def build : Bool
    unless git_clone_repo.success?
      Log.error { "Failed to clone URL: #{source_url}" }
      raise "Failed to clone URL: #{source_url}"
    end

    unless git_checkout.success?
      Log.error { "Failed to checkout version #{version}" }
      raise "Failed to checkout version #{version}"
    end

    Log.info { "Removing existing docs folder..." }
    execute("rm", ["-rf", "#{temp_folder}/docs"])

    unless shards_install.success?
      Log.error { "Failed to install shards" }
      raise "Failed to install shards"
    end

    unless crystal_doc.success?
      Log.error { "Failed to build docs" }
      raise "Failed to build docs"
    end

    post_process

    # make destination folder if necessary
    Log.info { "Deleting destination folder..." }
    execute("rm", ["-rf", "../public#{repo_path}/#{version}"])

    # make destination folder if necessary
    Log.info { "Creating destination folder..." }
    unless execute("mkdir", ["-p", "../public#{repo_path}"]).success?
      Log.error { "Failed to create destination folder" }
      raise "Failed to create destination folder"
    end

    # move ./docs folder to destination folder
    Log.info { "Copying docs to destination folder..." }
    unless execute("mv", ["docs", "../public#{repo_path}/#{version}"]).success?
      Log.error { "Failed to copy docs to destination folder" }
      raise "Failed to copy docs to destination folder"
    end

    return true
  rescue ex
    Log.error { "Builder Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}" }

    # remove destination folder
    `rm -rf "./public#{repo_path}/#{version}"`

    # re-create destination folder
    `mkdir -p "./public#{repo_path}/#{version}"`

    # render build failure template
    File.write "./public#{repo_path}/#{version}/index.html",
      CrystalDoc::Views::BuildFailureTemplate.new(source_url)

    return false
  ensure
    # ensure removal of temp folder
    `rm -rf "#{temp_folder}"`
  end

  private def repo_path : String
    "/#{service}/#{username}/#{project_name}"
  end

  private def temp_folder : String
    @temp_folder ||= Path["#{service}-#{username}-#{project_name}-#{version}"].expand.to_s
  end

  private def git_clone_repo : Process::Status
    Log.info { "Cloning repo..." }

    stdout = IO::Memory.new
    stderr = IO::Memory.new

    result = Process.run(
      "git",
      ["clone", source_url, temp_folder],
      env: {"GIT_TERMINAL_PROMPT" => "0", "POSTGRES_DB" => ""},
      output: stdout, error: stderr
    )

    Log.info { "git_clone_repo: " + stdout.to_s } unless stdout.to_s.empty?
    Log.error { "git_clone_repo: " + stderr.to_s } unless stderr.to_s.empty?

    result
  end

  private def git_checkout : Process::Status
    Log.info { "Checking out version #{version}..." }

    stdout = IO::Memory.new
    stderr = IO::Memory.new

    result = Process.run(
      "git",
      ["checkout", "--force", version],
      env: {"GIT_TERMINAL_PROMPT" => "0", "POSTGRES_DB" => ""},
      chdir: temp_folder,
      output: stdout, error: stderr
    )

    Log.info { "git_checkout: " + stdout.to_s } unless stdout.to_s.empty?
    Log.error { "git_checkout: " + stderr.to_s } unless stderr.to_s.empty?

    result
  end

  private def shards_install : Process::Status
    Log.info { "Running shards install..." }

    Dir.mkdir("#{temp_folder}/lib")

    safe_execute(
      "shards",
      [
        "install",
        "--without-development",
        "--skip-postinstall",
        "--skip-executables",
      ],
      # Need to be able to create the shard.lock if it doesn't exist
      rw_dirs: [temp_folder],
      ro_dirs: [Path[temp_folder].parent.to_s],
      networking: true
    )
  end

  private def crystal_doc : Process::Status
    Log.info { "Building docs..." }

    Dir.mkdir("#{temp_folder}/docs")

    safe_execute(
      "crystal",
      [
        "doc",
        "--json-config-url=#{repo_path}/versions.json",
        "--source-refname=#{version}",
        "--project-version=#{version}",
      ],
      rw_dirs: ["#{temp_folder}/docs"],
      ro_dirs: [temp_folder],
      networking: false
    )
  end

  private def execute(cmd : String, args : Array(String)) : Process::Status
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    Log.info { "Executing: #{cmd} #{args.join(" ")}" }

    result = Process.run(
      cmd, args,
      chdir: temp_folder,
      env: {"POSTGRES_DB" => ""},
      output: stdout, error: stderr
    )

    Log.info { "execute #{cmd}: " + stdout.to_s } unless stdout.to_s.empty?
    Log.error { "execute #{cmd}: " + stderr.to_s } unless stderr.to_s.empty?

    result
  end

  def safe_execute(cmd : String, args : Array(String),
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

    Log.info { "Safe executing: firejail #{fj_args.join(" ")}" }

    result = Process.run("firejail", fj_args,
      chdir: temp_folder,
      env: {"POSTGRES_DB" => ""},
      output: stdout, error: stderr
    )

    Log.info { "safe execute #{cmd}: " + stdout.to_s } unless stdout.to_s.empty?
    Log.error { "safe execute #{cmd}: " + stderr.to_s } unless stderr.to_s.empty?

    result
  end

  private def post_process : Nil
    Log.info { "Post processing..." }

    CrystalDoc::Html.post_process("#{temp_folder}/docs") do |html, file_path|
      sidebar = html.css(".sidebar").first
      sidebar["style"] = "display: flex; flex-direction: column; padding-top: 8px"

      html.head!.inner_html += <<-HTML
        <script data-goatcounter="https://crystaldoc-info.goatcounter.com/count" async src="//gc.zgo.at/count.js"></script>
      HTML

      sidebar.inner_html += <<-HTML
        <div style="margin-top: auto; padding: 27px 15px 9px 30px;">
          <small>
            Built with Crystal #{Crystal::VERSION}<br>#{Time.utc}
          </small>
        </div>
      HTML

      sidebar_header = html.css(".sidebar-header").first
      sidebar_search_box = sidebar_header.css(".search-box").first
      sidebar_project_summary = sidebar_header.css(".project-summary").first

      # Repos not on github aren't on shards.info
      shards_info_link = service == "github" ? <<-HTML : ""
        <a style="margin: 0 10px 0 0" href='https://shards.info/github/#{username}/#{project_name}'>
          Shards.info
        </a>
      HTML

      sidebar_header.inner_html = <<-HTML + sidebar_search_box.to_html + sidebar_project_summary.to_html
        <div class="crystaldoc-info-header" style="padding: 9px 15px 9px 30px">
          <h1 class="project-name" style="margin: 8px 0 8px 0; color: #F8F4FD">
            <a href="/">CrystalDoc.info</a>
          </h1>
          <div style="margin: 16px 0 0 0">
            <a style="margin: 0 12px 0 0" href="#{source_url}">Source code</a>
            #{shards_info_link}
          </div>
        </div>
      HTML
    end
  end
end
