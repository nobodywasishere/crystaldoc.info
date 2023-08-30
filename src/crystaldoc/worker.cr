module CrystalDoc
  class Worker
    PROJECT_ROOT = Path[__DIR__].parent.parent

    def self.execute_firejail(cmd : String, args : Array(String), directory : String)
      directory = Path[directory].absolute? ? directory : PROJECT_ROOT / directory

      Process.run("firejail", [
        "--noprofile",
        "--read-only=#{PROJECT_ROOT}",
        "--read-write=#{directory}",
        "--restrict-namespaces",
        "--rlimit-as=3g",
        "--timeout=00:15:00",
        cmd,
        *args,
      ],
        output: STDOUT, error: STDERR
      )
    end

    def self.generate_docs(repo : CrystalDoc::Repo, version : CrystalDoc::RepoVersion)
      temp_folder = Path["#{repo.username}-#{repo.project_name}-#{version.commit_id}"].expand

      # clone repo from site
      unless Process.run("git", ["clone", repo.source_url, temp_folder.to_s], output: STDOUT, error: STDERR, env: {"GIT_TERMINAL_PROMPT" => "0"}).success?
        raise "Failed to clone URL: #{repo.source_url}"
      end

      # Create public folder if necessary
      `mkdir -p "public#{repo.path}"`

      # cd into repo
      Dir.cd(temp_folder) do
        return "Documentation already exists" if File.exists? "../public#{repo.path}/#{version.commit_id}"

        `GIT_TERMINAL_PROMPT=0 git checkout --force "#{version.commit_id}"`

        `rm -rf docs`

        # shards install to install dependencies
        # return an error if this fails
        unless execute_firejail("shards", ["install", "--without-development", "--skip-postinstall", "--skip-executables"], temp_folder.to_s).success?
          raise "Failed to install dependencies via shard"
        end

        # generate docs using crystal
        # return an error if this fails
        unless execute_firejail("crystal", ["doc", "--json-config-url=#{repo.path}/versions.json", "--source-refname=#{version.commit_id}"], temp_folder.to_s).success?
          raise "Failed to generate documentation with Crystal"
        end

        CrystalDoc::Html.post_process("docs") do |html, file_path|
          sidebar_header = html.css(".sidebar-header").first
          sidebar_search_box = sidebar_header.css(".search-box").first
          sidebar_project_summary = sidebar_header.css(".project-summary").first

          sidebar_header.inner_html = <<-HTML + sidebar_search_box.to_html + sidebar_project_summary.to_html
          <div>
            <h1 class="project-name" style="padding: 9px 15px 9px 30px; margin: 8px 0 0 0; color: #F8F4FD">
              <a href="/">CrystalDoc.info</a>
            </h1>
          </div>
          HTML
        end

        # copy docs to `/public/:site/:repo/:user` folder
        `mv "docs" "../public#{repo.path}/#{version.commit_id}"`
      rescue ex
        `rm -rf "../public#{repo.path}/#{version.commit_id}"`
        `mkdir -p "../public#{repo.path}/#{version.commit_id}"`
        File.write "../public#{repo.path}/#{version.commit_id}/index.html",
          CrystalDoc::Views::BuildFailureTemplate.new(repo)

        return "Failed to generate documentation for #{repo.path}: #{ex}"
      end

      "Generated #{repo.path} documentation"
    ensure
      `rm -rf "#{temp_folder}"`
    end
  end
end
