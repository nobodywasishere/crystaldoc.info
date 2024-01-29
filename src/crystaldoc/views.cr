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
      getter repos : Array(Repo)
      getter repo_data : Hash(Repo, Ext::Data?)

      def initialize(@repos, @repo_data)
      end

      ECR.def_to_s "src/views/repo_list.ecr"
    end

    def self.format_span(span : Time::Span) : String
      span = span.abs
      time = [] of String
      time << " #{span.days}d" if span.total_days.floor > 0
      time << " %02d:%02d:%02d" % [span.hours, span.minutes, span.seconds]
      time.join("").strip
    end
  end
end
