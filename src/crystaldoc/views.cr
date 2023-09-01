require "ecr"

module CrystalDoc
  module Views
    # Borrowed from crystal source code
    # https://github.com/crystal-lang/crystal/blob/1.9.1/src/compiler/crystal/tools/doc/templates.cr
    struct StyleTemplate
      ECR.def_to_s "src/views/css/style.css"
    end

    class BuildFailureTemplate
      def initialize(@source_url : String)
      end

      ECR.def_to_s "src/views/layout.ecr"

      def content
        ECR.render("src/views/build_failure.ecr")
      end
    end

    class RepoList
      getter repos : Array(Hash(String, String))

      def initialize(@repos)
      end

      ECR.def_to_s "src/views/repo_list.ecr"
    end
  end
end
