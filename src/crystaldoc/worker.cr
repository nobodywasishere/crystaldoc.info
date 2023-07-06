module CrystalDoc
  class Worker
    def self.generate_docs(repo : CrystalDoc::Repository)
      temp_folder = "#{repo.user}-#{repo.proj}"

      # clone repo from site
      unless Process.run("git", ["clone", repo.url, temp_folder]).success?
        raise "Failed to clone URL: #{repo.site}"
      end
      # `git clone #{site} "#{user}-#{repo}"`

      `rm -rf "public/#{repo.site}/#{repo.user}/#{repo.proj}"`

      # Create public folder if necessary
      `mkdir -p "public/#{repo.site}/#{repo.user}/#{repo.proj}"`

      # cd into repo
      Dir.cd(temp_folder) do
        if repo.versions.empty?
          repo.versions.add(`git describe --tags --abbrev=0`.strip)
        end

        repo.versions.each do |version|
          `git checkout "#{version}"`

          # shards install to install dependencies
          # return an error if this fails
          unless Process.run("shards", ["install", "----without-development", "--skip-postinstall", "--skip-executables"]).success?
            raise "Failed to install dependencies via shard"
          end

          # generate docs using crystal
          # return an error if this fails
          unless Process.run("crystal", ["doc", "--json-config-url=/#{repo.site}/#{repo.user}/#{repo.proj}/versions.json"]).success?
            raise "Failed to generate documentation with Crystal"
          end

          # copy docs to `/public/:site/:repo/:user` folder
          `mv "docs" "../public/#{repo.site}/#{repo.user}/#{repo.proj}/#{version}"`
        end
      end

      "Generated #{repo.site} documentation"
    ensure
      `rm -rf "#{temp_folder}"`
    end
  end
end
