require "html"

class CrystalDoc::DocsBuilder
  getter source_url : String
  getter service : String
  getter username : String
  getter project_name : String
  getter version : String

  def initialize(@source_url, @service, @username, @project_name, @version)
  end

  def build : Nil
    # git clone to temp folder
    log "Cloning repo..."
    unless git_clone_repo.success?
      raise "Failed to clone URL: #{source_url}"
    end
    log "Success."

    # cd into repository folder
    Dir.cd(temp_folder) do
      log "Checking out version #{version}..."
      # force checkout specific version
      unless git_checkout.success?
        raise "Failed to checkout version #{version}"
      end
      log "Success."

      # remove ./docs folder
      `rm -rf docs`

      log "Pre processing..."
      pre_process
      log "Success."

      # shards install
      log "Running shards install..."
      unless shards_install.success?
        raise "Failed to install shards"
      end
      log "Success."

      # build docs
      log "Building docs..."
      unless crystal_doc.success?
        raise "Failed to build docs"
      end
      log "Success."

      # post process
      log "Post processing..."
      post_process
      log "Success."

      # make destination folder if necessary
      log "Deleting destination folder..."
      execute("rm", ["-rf", "../public#{repo_path}/#{version}"])
      log "Success."

      # make destination folder if necessary
      log "Creating destination folder..."
      unless execute("mkdir", ["-p", "../public#{repo_path}"]).success?
        raise "Failed to create destination folder"
      end
      log "Success."

      log "Copying docs to destination folder..."
      # move ./docs folder to destination folder
      unless execute("mv", ["docs", "../public#{repo_path}/#{version}"]).success?
        raise "Failed to copy docs to destination folder"
      end
      log "Success."
    rescue ex
      puts "DocsBuilder Exception: #{ex}"

      # remove destination folder
      `rm -rf "../public#{repo_path}/#{version}"`

      # re-create destination folder
      `mkdir -p "../public#{repo_path}/#{version}"`

      # render build failure template
      File.write "../public#{repo_path}/#{version}/index.html",
        CrystalDoc::Views::BuildFailureTemplate.new(source_url)
    end
  ensure
    # ensure removal of temp folder
    `rm -rf "#{temp_folder}"`
  end

  private def repo_path : String
    "/#{service}/#{username}/#{project_name}"
  end

  private def temp_folder : String
    Path["#{service}-#{username}-#{project_name}-#{version}"].expand.to_s
  end

  private def git_clone_repo : Process::Status
    Process.run(
      "git",
      ["clone", source_url, temp_folder],
      env: {"GIT_TERMINAL_PROMPT" => "0"}
    )
  end

  private def git_checkout : Process::Status
    Process.run(
      "git",
      ["checkout", "--force", version],
      env: {"GIT_TERMINAL_PROMPT" => "0"}
    )
  end

  private def shards_install : Process::Status
    safe_execute(
      "shards",
      [
        "install",
        "--without-development",
        "--skip-postinstall",
        "--skip-executables",
      ],
      "#{temp_folder}/lib",
      temp_folder
    )
  end

  private def crystal_doc : Process::Status
    safe_execute(
      "crystal",
      [
        "doc",
        "--json-config-url=#{repo_path}/versions.json",
        "--source-refname=#{version}",
      ],
      "#{temp_folder}/docs",
      temp_folder
    )
  end

  private def execute(cmd : String, args : Array(String)) : Process::Status
    Process.run(cmd, args)
  end

  private def safe_execute(cmd : String, args : Array(String), rw_directory : String, ro_directory : String) : Process::Status
    Process.run("firejail", [
      "--noprofile",
      "--read-only=#{ro_directory}",
      "--read-write=#{rw_directory}",
      "--restrict-namespaces",
      "--rlimit-as=3g",
      "--timeout=00:15:00",
      cmd,
      *args,
    ],
      output: STDOUT, error: STDERR
    )
  end

  private def pre_process : Nil
    # For each file, read and modify
    code_block = false
    "".each_line do |line|
      if /^\s*#/.match(line)
        if line.includes? "```"
          code_block = !code_block
        end

        unless code_block
          line = HTML.escape(line)
        end
      end
    end
  end

  private def post_process : Nil
    CrystalDoc::Html.post_process("docs") do |html, file_path|
      sidebar_header = html.css(".sidebar-header").first
      sidebar_search_box = sidebar_header.css(".search-box").first
      sidebar_project_summary = sidebar_header.css(".project-summary").first

      sidebar_header.inner_html = <<-HTML + sidebar_search_box.to_html + sidebar_project_summary.to_html
        <div class="crystaldoc-info-header" style="padding: 9px 15px 20px 30px; border-bottom: 1px solid #E6E6E6">
          <h1 class="project-name" style="margin: 8px 0 8px 0; color: #F8F4FD">
            <a href="/">CrystalDoc.info</a>
          </h1>
          <small>
            Crystal #{Crystal::VERSION}
            <br>
            #{Time.utc}
          </small>
        </div>
      HTML
    end
  end

  private def log(info : String)
    if true
      puts info
    end
  end
end
