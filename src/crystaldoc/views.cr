require "ecr"

module CrystalDoc
  module Views
    class Sidebar
      getter repo_list : Array(CrystalDoc::Repo)
      getter repo_hash : Hash(String, Array(CrystalDoc::Repo))

      def initialize
        @repo_list = DB.open(ENV["POSTGRES_DB"]) do |db|
          db.transaction do |tx|
            CrystalDoc::Queries
              .get_repos(tx.connection)
              .sort_by{ |r| "#{r.username}/#{r.project_name}" }
          end
        end || [] of CrystalDoc::Repo

        @repo_hash = {} of String => Array(CrystalDoc::Repo)
        @repo_list.each do |r|
          @repo_hash[r.username] ||= [] of CrystalDoc::Repo
          @repo_hash[r.username].push(r)
        end
      end

      ECR.def_to_s "./src/views/sidebar.ecr"
    end

    # Borrowed from crystal source code
    # https://github.com/crystal-lang/crystal/blob/1.9.1/src/compiler/crystal/tools/doc/templates.cr
    SVG_DEFS = <<-SVG
    <svg class="hidden">
      <symbol id="octicon-link" viewBox="0 0 16 16">
        <path fill-rule="evenodd" d="M4 9h1v1H4c-1.5 0-3-1.69-3-3.5S2.55 3 4 3h4c1.45 0 3 1.69 3 3.5 0 1.41-.91 2.72-2 3.25V8.59c.58-.45 1-1.27 1-2.09C10 5.22 8.98 4 8 4H4c-.98 0-2 1.22-2 2.5S3 9 4 9zm9-3h-1v1h1c1 0 2 1.22 2 2.5S13.98 12 13 12H9c-.98 0-2-1.22-2-2.5 0-.83.42-1.64 1-2.09V6.25c-1.09.53-2 1.84-2 3.25C6 11.31 7.55 13 9 13h4c1.45 0 3-1.69 3-3.5S14.5 6 13 6z"></path>
      </symbol>
    </svg>
    SVG

    SIDEBAR_BUTTON = <<-HTML
    <input type="checkbox" id="sidebar-btn">
    <label for="sidebar-btn" id="sidebar-btn-label">
      <svg class="open" xmlns="http://www.w3.org/2000/svg" height="2em" width="2em" viewBox="0 0 512 512"><title>Open Sidebar</title><path fill="currentColor" d="M80 96v64h352V96H80zm0 112v64h352v-64H80zm0 112v64h352v-64H80z"></path></svg>
      <svg class="close" xmlns="http://www.w3.org/2000/svg" width="2em" height="2em" viewBox="0 0 512 512"><title>Close Sidebar</title><path fill="currentColor" d="m118.6 73.4-45.2 45.2L210.7 256 73.4 393.4l45.2 45.2L256 301.3l137.4 137.3 45.2-45.2L301.3 256l137.3-137.4-45.2-45.2L256 210.7Z"></path></svg>
    </label>
    HTML

    class JsTypeTemplate
      ECR.def_to_s "src/views/js/doc.js"
    end

    struct JsSearchTemplate
      ECR.def_to_s "src/views/js/_search.js"
    end

    struct JsNavigatorTemplate
      ECR.def_to_s "src/views/js/_navigator.js"
    end

    struct JsVersionsTemplate
      ECR.def_to_s "src/views/js/_versions.js"
    end

    struct JsUsageModal
      ECR.def_to_s "src/views/js/_usage-modal.js"
    end

    struct StyleTemplate
      ECR.def_to_s "src/views/css/style.css"
    end
    # End borrowed code

  end
end
