require "ecr"

module CrystalDoc
  module Views
    class Sidebar
      getter repo_list : Array(CrystalDoc::Repo)

      def initialize
        @repo_list = DB.open(ENV["POSTGRES_DB"]) do |db|
          db.transaction do |tx|
            CrystalDoc::Queries.get_repos(tx.connection).sort_by{ |r| "#{r.username}/#{r.project_name}" }
          end
        end || [] of CrystalDoc::Repo
      end

      ECR.def_to_s "./src/views/sidebar.ecr"
    end
  end
end
