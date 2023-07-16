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

    def self.generate_docs(repo : CrystalDoc::Repo)
      temp_folder = Path["#{repo.username}-#{repo.project_name}"].expand

      # clone repo from site
      unless Process.run("git", ["clone", repo.source_url, temp_folder.to_s], output: STDOUT, error: STDERR).success?
        raise "Failed to clone URL: #{repo.source_url}"
      end

      `rm -rf "public/#{repo.path}"`

      # Create public folder if necessary
      `mkdir -p "public/#{repo.path}"`

      # cd into repo
      Dir.cd(temp_folder) do
        repo.versions.each do |version|
          next if File.exists? "../public#{repo.path}/#{version.commit_id}"

          p version
          `git checkout "#{version.commit_id}"`

          # shards install to install dependencies
          # return an error if this fails
          unless execute_firejail("shards", ["install", "--without-development", "--skip-postinstall", "--skip-executables"], temp_folder.to_s).success?
            raise "Failed to install dependencies via shard"
          end

          # generate docs using crystal
          # return an error if this fails
          unless execute_firejail("crystal", ["doc", "--json-config-url=#{repo.path}/versions.json"], temp_folder.to_s).success?
            raise "Failed to generate documentation with Crystal"
          end

          # copy docs to `/public/:site/:repo/:user` folder
          `mv "docs" "../public/#{repo.path}/#{version.commit_id}"`
        rescue
          puts "Failed to generate documentation for #{repo.path}"
        end
      end

      "Generated #{repo.path} documentation"
    ensure
      `rm -rf "#{temp_folder}"`
    end
  end
end
