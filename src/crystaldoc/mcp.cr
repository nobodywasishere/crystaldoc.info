require "json"

module CrystalDoc::MCP
  PROTOCOL_VERSION = "2024-11-05"
  SERVER_NAME      = "crystaldoc-mcp"
  SERVER_VERSION   = "0.1.0"

  DocCacheInstance = CrystalDoc::MCP::DocCache.new

  def self.handle(request : JSON::Any, db : Queriable) : String
    id = request["id"]?

    method = request["method"]?.try(&.as_s?)
    unless method
      return rpc_error(id, -32_600, "Invalid Request: no method")
    end

    params = request["params"]?

    case method
    when "initialize"
      handle_initialize(id)
    when "notifications/initialized"
      ""
    when "tools/list"
      handle_tools_list(id)
    when "tools/call"
      handle_tools_call(id, params, db)
    when "resources/list"
      handle_resources_list(id, params)
    when "resources/read"
      handle_resources_read(id, params, db)
    when "ping"
      rpc_result(id) { |j| j.object { } }
    else
      rpc_error(id, -32_601, "Method not found: #{method}")
    end
  end

  def self.handle_streamable_http(body : String, db : Queriable) : {Int32, String}
    request = JSON.parse(body)

    unless request.raw.is_a?(Hash)
      return {400, parse_error_response}
    end

    response = handle(request, db)
    return {202, ""} if response.empty?

    {200, response}
  rescue JSON::ParseException
    {400, parse_error_response}
  end

  # ── JSON-RPC response helpers ──────────────────────────────────────

  def self.parse_error_response : String
    rpc_error(JSON::Any.new(nil), -32_700, "Parse error")
  end

  private def self.parse_repo(repo : String?) : {String, String, String}?
    repo_str = repo.try(&.strip)
    return unless repo_str
    return if repo_str.empty?

    parts = repo_str.split("/")
    return unless parts.size == 3 && parts.none?(&.empty?)

    {parts[0], parts[1], parts[2]}
  end

  private def self.resolve_version(db : Queriable, repo_str : String, service : String, user : String, project : String, version : String?) : String?
    return version unless version.nil? || version.empty?

    CrystalDoc::Queries.latest_version(db, service, user, project)
  rescue
    nil
  end

  private def self.write_id(j : JSON::Builder, id : JSON::Any?) : Nil
    if id
      case raw = id.raw
      when Int64   then j.number raw
      when String  then j.string raw
      when Float64 then j.number raw
      else              j.null
      end
    else
      j.null
    end
  end

  def self.rpc_error(id : JSON::Any?, code : Int32, message : String) : String
    String.build do |io|
      JSON.build(io) do |j|
        j.object do
          j.field "jsonrpc", "2.0"
          j.field "id" { write_id(j, id) }
          j.field "error" do
            j.object do
              j.field "code", code
              j.field "message", message
            end
          end
        end
      end
    end
  end

  private def self.rpc_result(id : JSON::Any?, & : JSON::Builder ->) : String
    String.build do |io|
      JSON.build(io) do |j|
        j.object do
          j.field "jsonrpc", "2.0"
          j.field "id" { write_id(j, id) }
          j.field "result" do
            yield j
          end
        end
      end
    end
  end

  # ── handlers ───────────────────────────────────────────────────────

  private def self.handle_initialize(id : JSON::Any?) : String
    rpc_result(id) do |j|
      j.object do
        j.field "protocolVersion", PROTOCOL_VERSION
        j.field "capabilities" do
          j.object do
            j.field "tools" do
              j.object do
                j.field "listChanged", false
              end
            end
            j.field "resources" do
              j.object do
                j.field "listChanged", false
              end
            end
          end
        end
        j.field "serverInfo" do
          j.object do
            j.field "name", SERVER_NAME
            j.field "version", SERVER_VERSION
          end
        end
      end
    end
  end

  private def self.handle_tools_list(id : JSON::Any?) : String
    rpc_result(id) do |j|
      j.object do
        j.field "tools" do
          j.array do
            # search_documentation
            j.object do
              j.field "name", "search_documentation"
              j.field "description", "Search for types (classes, modules, structs, enums) by name within a specific repository. Requires a repo to limit scope."
              j.field "inputSchema" do
                j.object do
                  j.field "type", "object"
                  j.field "properties" do
                    j.object do
                      j.field "query" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Search query to match against type names (case-insensitive substring match)"
                        end
                      end
                      j.field "repo" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Repo path in the form service/user/project (e.g. github/icyleaf/markd)"
                        end
                      end
                    end
                  end
                  j.field "required" do
                    j.array do
                      j.string "query"
                      j.string "repo"
                    end
                  end
                end
              end
            end

            # search_types
            j.object do
              j.field "name", "search_types"
              j.field "description", "Get full documentation for a specific type (class, module, struct, enum) by its fully qualified name. Returns methods, constants, ancestors, source locations, and nested types."
              j.field "inputSchema" do
                j.object do
                  j.field "type", "object"
                  j.field "properties" do
                    j.object do
                      j.field "full_name" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Fully qualified type name using Crystal's :: notation (e.g. Larimar::Controller)"
                        end
                      end
                      j.field "repo" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Repo path in the form service/user/project (e.g. github/nobodywasishere/larimar)"
                        end
                      end
                      j.field "version" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Optional: documentation version tag. Defaults to the latest valid version."
                        end
                      end
                    end
                  end
                  j.field "required" do
                    j.array do
                      j.string "full_name"
                      j.string "repo"
                    end
                  end
                end
              end
            end

            # list_repos
            j.object do
              j.field "name", "list_repos"
              j.field "description", "Search and list shard repositories that have documentation available on CrystalDoc.info."
              j.field "inputSchema" do
                j.object do
                  j.field "type", "object"
                  j.field "properties" do
                    j.object do
                      j.field "query" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Optional: search query to filter repositories by username or project name"
                        end
                      end
                    end
                  end
                end
              end
            end

            # list_versions
            j.object do
              j.field "name", "list_versions"
              j.field "description", "List available documentation versions for a repository."
              j.field "inputSchema" do
                j.object do
                  j.field "type", "object"
                  j.field "properties" do
                    j.object do
                      j.field "repo" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Repo path in the form service/user/project (e.g. github/crystal-lang/shards)"
                        end
                      end
                    end
                  end
                  j.field "required" do
                    j.array { j.string "repo" }
                  end
                end
              end
            end

            # get_readme
            j.object do
              j.field "name", "get_readme"
              j.field "description", "Get the repository README for a documented version. Returns the rendered README source stored with the generated docs."
              j.field "inputSchema" do
                j.object do
                  j.field "type", "object"
                  j.field "properties" do
                    j.object do
                      j.field "repo" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Repo path in the form service/user/project (e.g. github/icyleaf/markd)"
                        end
                      end
                      j.field "version" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Optional: documentation version tag. Defaults to the latest valid version."
                        end
                      end
                    end
                  end
                  j.field "required" do
                    j.array { j.string "repo" }
                  end
                end
              end
            end

            # search_methods
            j.object do
              j.field "name", "search_methods"
              j.field "description", "Search for methods by name within a specific repository. Requires a repo to limit scope."
              j.field "inputSchema" do
                j.object do
                  j.field "type", "object"
                  j.field "properties" do
                    j.object do
                      j.field "query" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Method name to search for (case-insensitive substring match, e.g. 'accepts_lines')"
                        end
                      end
                      j.field "repo" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Repo path in the form service/user/project (e.g. github/icyleaf/markd)"
                        end
                      end
                    end
                  end
                  j.field "required" do
                    j.array do
                      j.string "query"
                      j.string "repo"
                    end
                  end
                end
              end
            end

            # search_constants
            j.object do
              j.field "name", "search_constants"
              j.field "description", "Search for constants by name within a specific repository. Useful for protocol names, defaults, and configuration values."
              j.field "inputSchema" do
                j.object do
                  j.field "type", "object"
                  j.field "properties" do
                    j.object do
                      j.field "query" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Constant name to search for (case-insensitive substring match, e.g. 'DEFAULT' or 'VERSION')"
                        end
                      end
                      j.field "repo" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Repo path in the form service/user/project (e.g. github/icyleaf/markd)"
                        end
                      end
                    end
                  end
                  j.field "required" do
                    j.array do
                      j.string "query"
                      j.string "repo"
                    end
                  end
                end
              end
            end

            # get_method_details
            j.object do
              j.field "name", "get_method_details"
              j.field "description", "Get detailed documentation for a specific method, including signature, source location, and indexed method body when available."
              j.field "inputSchema" do
                j.object do
                  j.field "type", "object"
                  j.field "properties" do
                    j.object do
                      j.field "repo" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Repo path in the form service/user/project (e.g. github/icyleaf/markd)"
                        end
                      end
                      j.field "type_name" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Fully qualified type or module name that owns the method (e.g. Markd::Node)"
                        end
                      end
                      j.field "method_name" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Exact method name to look up (e.g. first_child or to_html)"
                        end
                      end
                      j.field "kind" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Optional method kind filter: constructor, instance, or class"
                        end
                      end
                      j.field "version" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Optional: documentation version tag. Defaults to the latest valid version."
                        end
                      end
                    end
                  end
                  j.field "required" do
                    j.array do
                      j.string "repo"
                      j.string "type_name"
                      j.string "method_name"
                    end
                  end
                end
              end
            end

            # list_api
            j.object do
              j.field "name", "list_api"
              j.field "description", "List documented types in a repository version. By default this returns top-level types; pass a namespace to scope the results to nested types under that namespace."
              j.field "inputSchema" do
                j.object do
                  j.field "type", "object"
                  j.field "properties" do
                    j.object do
                      j.field "repo" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Repo path in the form service/user/project (e.g. github/nobodywasishere/larimar)"
                        end
                      end
                      j.field "version" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Optional: documentation version tag. Defaults to the latest valid version."
                        end
                      end
                      j.field "namespace" do
                        j.object do
                          j.field "type", "string"
                          j.field "description", "Optional: fully qualified type or module name whose nested documented types should be listed (e.g. Larimar or Markd::Parser)"
                        end
                      end
                    end
                  end
                  j.field "required" do
                    j.array { j.string "repo" }
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  private def self.handle_tools_call(id : JSON::Any?, params : JSON::Any?, db : Queriable) : String
    unless params
      return rpc_error(id, -32_602, "Invalid params: params is required")
    end

    tool_name = params["name"]?.try(&.as_s?)
    args = params["arguments"]?

    unless tool_name
      return rpc_error(id, -32_602, "Invalid params: no tool name")
    end

    case tool_name
    when "search_documentation"
      call_search_documentation(id, args)
    when "search_types"
      call_get_type(id, args, db)
    when "list_repos"
      call_list_repos(id, args, db)
    when "list_versions"
      call_list_versions(id, args, db)
    when "get_readme"
      call_get_readme(id, args, db)
    when "search_methods"
      call_search_methods(id, args)
    when "search_constants"
      call_search_constants(id, args)
    when "get_method_details"
      call_get_method_details(id, args, db)
    when "list_api"
      call_list_api(id, args, db)
    else
      rpc_error(id, -32_601, "Unknown tool: #{tool_name}")
    end
  end

  # ── tool implementations ───────────────────────────────────────────

  private def self.call_search_documentation(id : JSON::Any?, args : JSON::Any?) : String
    unless args
      return rpc_error(id, -32_602, "Invalid params: arguments is required")
    end

    query = args["query"]?.try(&.as_s?)
    repo_str = args["repo"]?.try(&.as_s?).try(&.strip)

    if query.nil? || query.empty?
      return rpc_error(id, -32_602, "Invalid params: query is required")
    end
    if repo_str.nil? || repo_str.empty?
      return rpc_error(id, -32_602, "Invalid params: repo is required")
    end
    unless parse_repo(repo_str)
      return rpc_error(id, -32_602, "Invalid repo format: expected service/user/project")
    end

    results = DocCacheInstance.search_types(query, repo_str)

    rpc_result(id) do |j|
      j.object do
        j.field "content" do
          j.array do
            j.object do
              j.field "type", "text"
              if results.empty?
                j.field "text", "No types found matching \"#{query}\"."
              else
                lines = ["Found #{results.size} type(s):\n"]
                results.each do |_result|
                  lines << "  - **#{_result.full_name}** (#{_result.kind})"
                  lines << "    Repo: #{_result.repo} @ #{_result.version}"
                  lines << "    URL: /#{_result.repo}/#{_result.version}/#{_result.path}"
                end
                j.field "text", lines.join("\n")
              end
            end
          end
        end
      end
    end
  end

  private def self.call_search_methods(id : JSON::Any?, args : JSON::Any?) : String
    unless args
      return rpc_error(id, -32_602, "Invalid params: arguments is required")
    end

    query = args["query"]?.try(&.as_s?)
    repo_str = args["repo"]?.try(&.as_s?).try(&.strip)

    if query.nil? || query.empty?
      return rpc_error(id, -32_602, "Invalid params: query is required")
    end
    if repo_str.nil? || repo_str.empty?
      return rpc_error(id, -32_602, "Invalid params: repo is required")
    end
    unless parse_repo(repo_str)
      return rpc_error(id, -32_602, "Invalid repo format: expected service/user/project")
    end

    results = DocCacheInstance.search_methods(query, repo_str)

    rpc_result(id) do |j|
      j.object do
        j.field "content" do
          j.array do
            j.object do
              j.field "type", "text"
              if results.empty?
                j.field "text", "No methods found matching \"#{query}\"."
              else
                lines = ["Found #{results.size} method(s):\n"]
                results.each do |_m|
                  lines << "  - `#{_m.method_name}` (#{_m.method_kind} method in **#{_m.full_name}**)"
                  lines << "    Repo: #{_m.repo} @ #{_m.version}"
                end
                j.field "text", lines.join("\n")
              end
            end
          end
        end
      end
    end
  end

  private def self.call_search_constants(id : JSON::Any?, args : JSON::Any?) : String
    unless args
      return rpc_error(id, -32_602, "Invalid params: arguments is required")
    end

    query = args["query"]?.try(&.as_s?)
    repo_str = args["repo"]?.try(&.as_s?).try(&.strip)

    if query.nil? || query.empty?
      return rpc_error(id, -32_602, "Invalid params: query is required")
    end
    if repo_str.nil? || repo_str.empty?
      return rpc_error(id, -32_602, "Invalid params: repo is required")
    end
    unless parse_repo(repo_str)
      return rpc_error(id, -32_602, "Invalid repo format: expected service/user/project")
    end

    results = DocCacheInstance.search_constants(query, repo_str)

    rpc_result(id) do |j|
      j.object do
        j.field "content" do
          j.array do
            j.object do
              j.field "type", "text"
              if results.empty?
                j.field "text", "No constants found matching \"#{query}\"."
              else
                lines = ["Found #{results.size} constant(s):\n"]
                results.each do |const|
                  lines << "  - `#{const.name}` (in **#{const.full_name}**)"
                  lines << "    Repo: #{const.repo} @ #{const.version}"
                  unless const.value.empty?
                    lines << "    Value: #{truncate_single_line(const.value)}"
                  end
                end
                j.field "text", lines.join("\n")
              end
            end
          end
        end
      end
    end
  end

  private def self.call_get_method_details(id : JSON::Any?, args : JSON::Any?, db : Queriable) : String
    unless args
      return rpc_error(id, -32_602, "Invalid params: arguments is required")
    end

    repo_str = args["repo"]?.try(&.as_s?)
    type_name = args["type_name"]?.try(&.as_s?)
    method_name = args["method_name"]?.try(&.as_s?)
    kind = args["kind"]?.try(&.as_s?)
    version_str = args["version"]?.try(&.as_s?)

    unless repo_str && type_name && method_name
      return rpc_error(id, -32_602, "Invalid params: repo, type_name, and method_name are required")
    end

    if kind && !{"constructor", "instance", "class"}.includes?(kind)
      return rpc_error(id, -32_602, "Invalid params: kind must be one of constructor, instance, or class")
    end

    repo = parse_repo(repo_str)
    unless repo
      return rpc_error(id, -32_602, "Invalid repo format: expected service/user/project")
    end

    service, user, project = repo

    version_str = resolve_version(db, repo_str, service, user, project, version_str)
    unless version_str
      return rpc_error(id, -32_602, "No valid version found for #{repo_str}")
    end

    method_details = DocCacheInstance.get_method(type_name, method_name, service, user, project, version_str, kind)

    unless method_details
      return method_not_found_response(id, method_name, kind, type_name, repo_str, version_str)
    end

    method_text = format_method_details(method_details, repo_str, version_str)

    rpc_result(id) do |j|
      j.object do
        j.field "content" do
          j.array do
            j.object do
              j.field "type", "text"
              j.field "text", method_text
            end
          end
        end
      end
    end
  end

  private def self.method_not_found_response(id : JSON::Any?, method_name : String, kind : String?, type_name : String, repo_str : String, version_str : String) : String
    rpc_result(id) do |j|
      j.object do
        j.field "content" do
          j.array do
            j.object do
              j.field "type", "text"
              kind_text = kind ? " (#{kind})" : ""
              j.field "text", "Method \"#{method_name}\"#{kind_text} not found on #{type_name} in #{repo_str} @ #{version_str}."
            end
          end
        end
        j.field "isError", true
      end
    end
  end

  private def self.call_get_type(id : JSON::Any?, args : JSON::Any?, db : Queriable) : String
    unless args
      return rpc_error(id, -32_602, "Invalid params: arguments is required")
    end

    full_name = args["full_name"]?.try(&.as_s?)
    repo_str = args["repo"]?.try(&.as_s?)
    version_str = args["version"]?.try(&.as_s?)

    unless full_name && repo_str
      return rpc_error(id, -32_602, "Invalid params: full_name and repo are required")
    end

    repo = parse_repo(repo_str)
    unless repo
      return rpc_error(id, -32_602, "Invalid repo format: expected service/user/project")
    end

    service, user, project = repo

    if version_str.nil? || version_str.empty?
      begin
        version_str = CrystalDoc::Queries.latest_version(db, service, user, project)
      rescue
        return rpc_error(id, -32_602, "Failed to look up latest version for #{repo_str}")
      end
      unless version_str
        return rpc_error(id, -32_602, "No valid version found for #{repo_str}")
      end
    end

    type_node = DocCacheInstance.get_type(full_name, service, user, project, version_str)

    unless type_node
      return rpc_result(id) do |j|
        j.object do
          j.field "content" do
            j.array do
              j.object do
                j.field "type", "text"
                j.field "text", "Type \"#{full_name}\" not found in #{repo_str} @ #{version_str}."
              end
            end
          end
          j.field "isError", true
        end
      end
    end

    type_text = format_type_details(type_node, repo_str, version_str)

    rpc_result(id) do |j|
      j.object do
        j.field "content" do
          j.array do
            j.object do
              j.field "type", "text"
              j.field "text", type_text
            end
          end
        end
      end
    end
  end

  private def self.call_list_repos(id : JSON::Any?, args : JSON::Any?, db : Queriable) : String
    query = args["query"]?.try(&.as_s?) if args

    repos = if query && !query.empty?
              if query.includes?("/")
                user, proj = query.split("/")[0..1]
                CrystalDoc::Queries.find_repo(db, user, proj, distinct: true)
              else
                CrystalDoc::Queries.find_repo(db, query, query, distinct: false)
              end
            else
              CrystalDoc::Queries.popular_repos(db, 20)
            end

    rpc_result(id) do |j|
      j.object do
        j.field "content" do
          j.array do
            j.object do
              j.field "type", "text"
              if repos.empty?
                j.field "text", "No repositories found."
              else
                lines = ["Found #{repos.size} repositor(ies):\n"]
                repos.each do |_repo|
                  lines << "  - **#{_repo.path}**"
                  lines << "    Source: #{_repo.source_url}"
                end
                j.field "text", lines.join("\n")
              end
            end
          end
        end
      end
    end
  end

  private def self.call_list_versions(id : JSON::Any?, args : JSON::Any?, db : Queriable) : String
    unless args
      return rpc_error(id, -32_602, "Invalid params: arguments is required")
    end

    repo_str = args["repo"]?.try(&.as_s?)

    unless repo_str
      return rpc_error(id, -32_602, "Invalid params: repo is required")
    end

    repo = parse_repo(repo_str)
    unless repo
      return rpc_error(id, -32_602, "Invalid repo format: expected service/user/project")
    end

    service, user, project = repo

    unless CrystalDoc::Queries.repo_exists(db, service, user, project)
      return rpc_result(id) do |j|
        j.object do
          j.field "content" do
            j.array do
              j.object do
                j.field "type", "text"
                j.field "text", "Repository \"#{repo_str}\" not found."
              end
            end
          end
          j.field "isError", true
        end
      end
    end

    versions_json = CrystalDoc::Queries.versions_json(db, service, user, project)
    versions_data = JSON.parse(versions_json)

    rpc_result(id) do |j|
      j.object do
        j.field "content" do
          j.array do
            j.object do
              j.field "type", "text"
              vs = versions_data["versions"]?.try(&.as_a?)
              if vs.nil? || vs.empty?
                j.field "text", "No valid versions found for #{repo_str}."
              else
                lines = ["Versions for #{repo_str}:\n"]
                vs.each do |version_info|
                  name = version_info["name"]?.try(&.as_s?) || "?"
                  release_info = version_info["released"]?.try(&.as_bool?) == true ? "release" : "nightly"
                  lines << "  - #{name} (#{release_info})"
                end
                j.field "text", lines.join("\n")
              end
            end
          end
        end
      end
    end
  end

  private def self.call_get_readme(id : JSON::Any?, args : JSON::Any?, db : Queriable) : String
    unless args
      return rpc_error(id, -32_602, "Invalid params: arguments is required")
    end

    repo_str = args["repo"]?.try(&.as_s?)
    version_str = args["version"]?.try(&.as_s?)

    unless repo_str
      return rpc_error(id, -32_602, "Invalid params: repo is required")
    end

    repo = parse_repo(repo_str)
    unless repo
      return rpc_error(id, -32_602, "Invalid repo format: expected service/user/project")
    end

    service, user, project = repo

    if version_str.nil? || version_str.empty?
      begin
        version_str = CrystalDoc::Queries.latest_version(db, service, user, project)
      rescue
        return rpc_error(id, -32_602, "Failed to look up latest version for #{repo_str}")
      end
      unless version_str
        return rpc_error(id, -32_602, "No valid version found for #{repo_str}")
      end
    end

    data = DocCacheInstance.get(service, user, project, version_str)
    unless data
      return rpc_result(id) do |j|
        j.object do
          j.field "content" do
            j.array do
              j.object do
                j.field "type", "text"
                j.field "text", "Documentation not found for #{repo_str} @ #{version_str}."
              end
            end
          end
          j.field "isError", true
        end
      end
    end

    body = data["body"]?.try(&.as_s?) || "No README available."

    rpc_result(id) do |j|
      j.object do
        j.field "content" do
          j.array do
            j.object do
              j.field "type", "text"
              j.field "text", body
            end
          end
        end
      end
    end
  end

  private def self.call_list_api(id : JSON::Any?, args : JSON::Any?, db : Queriable) : String
    unless args
      return rpc_error(id, -32_602, "Invalid params: arguments is required")
    end

    repo_str = args["repo"]?.try(&.as_s?)
    version_str = args["version"]?.try(&.as_s?)
    namespace = args["namespace"]?.try(&.as_s?)

    unless repo_str
      return rpc_error(id, -32_602, "Invalid params: repo is required")
    end

    repo = parse_repo(repo_str)
    unless repo
      return rpc_error(id, -32_602, "Invalid repo format: expected service/user/project")
    end

    service, user, project = repo

    version_str = resolve_version(db, repo_str, service, user, project, version_str)
    unless version_str
      return rpc_error(id, -32_602, "No valid version found for #{repo_str}")
    end

    results = DocCacheInstance.list_api_types(service, user, project, version_str, namespace)

    rpc_result(id) do |j|
      j.object do
        j.field "content" do
          j.array do
            j.object do
              j.field "type", "text"
              j.field "text", format_api_list(results, namespace, repo_str, version_str)
            end
          end
        end
      end
    end
  end

  # ── resource handlers ──────────────────────────────────────────────

  private def self.handle_resources_list(id : JSON::Any?, params : JSON::Any?) : String
    rpc_result(id) do |j|
      j.object do
        j.field "resources" do
          j.array do
            DocCacheInstance.list_repo_versions.each do |info|
              json_resource(j, "crystaldoc://#{info.service}/#{info.user}/#{info.project}/#{info.version}/readme",
                "#{info.service}/#{info.user}/#{info.project} @ #{info.version} README",
                "text/markdown")
            end
          end
        end
      end
    end
  end

  private def self.handle_resources_read(id : JSON::Any?, params : JSON::Any?, db : Queriable) : String
    unless params
      return rpc_error(id, -32_602, "Invalid params: params is required")
    end

    uri = params["uri"]?.try(&.as_s?)
    unless uri
      return rpc_error(id, -32_602, "Invalid params: uri is required")
    end

    if uri =~ /\Ahttps?:\/\//
      return rpc_error(id, -32_602, "Only crystaldoc:// URIs are supported")
    end

    parts = uri.split("/")

    # crystaldoc://service/user/project/version/readme
    # crystaldoc://service/user/project/version/type/full/name
    if parts.size >= 7 && parts[6] == "readme"
      service, user, project, version = parts[2], parts[3], parts[4], parts[5]

      data = DocCacheInstance.get(service, user, project, version)
      unless data
        return rpc_result(id) do |j|
          j.object do
            j.field "content" do
              j.array do
                j.object do
                  j.field "type", "text"
                  j.field "text", "Documentation not found for #{service}/#{user}/#{project} @ #{version}"
                end
              end
            end
            j.field "isError", true
          end
        end
      end

      body = data["body"]?.try(&.as_s?) || "No README available."

      rpc_result(id) do |j|
        j.object do
          j.field "contents" do
            j.array do
              j.object do
                j.field "uri", uri
                j.field "mimeType", "text/markdown"
                j.field "text", body
              end
            end
          end
        end
      end
    else
      rpc_error(id, -32_602, "Unknown resource: #{uri}")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────

  private def self.json_resource(j : JSON::Builder, uri : String, name : String, mime : String)
    j.object do
      j.field "uri", uri
      j.field "name", name
      j.field "mimeType", mime
    end
  end

  private def self.format_type_details(node : JSON::Any, repo_str : String, version : String) : String
    lines = [] of String
    format_type_header(lines, node, repo_str, version)
    format_doc_section(lines, node)
    format_source_location(lines, node)
    format_namespace_section(lines, node)
    format_included_modules_section(lines, node)
    format_constants_section(lines, node)
    format_constructors_section(lines, node)
    format_methods_section(lines, node, "instance_methods", "### Instance Methods")
    format_combined_methods_section(lines, node, ["class_methods", "methods"], "### Class Methods")
    format_nested_types_section(lines, node)
    lines.join("\n")
  end

  private def self.format_type_header(lines : Array(String), node : JSON::Any, repo_str : String, version : String)
    name = node["name"]?.try(&.as_s?) || "?"
    full_name = node["full_name"]?.try(&.as_s?) || name
    kind = node["kind"]?.try(&.as_s?) || "?"
    abs = node["abstract"]?.try(&.as_bool?) == true

    lines << "## #{full_name}"
    lines << "**Kind:** #{kind}#{abs ? " (abstract)" : ""}"
    lines << "**Repo:** #{repo_str} @ #{version}"

    if sup = node["superclass"]?
      if sup_name = sup["name"]?.try(&.as_s?)
        lines << "**Superclass:** #{sup_name}"
      end
    end

    if ancestors = node["ancestors"]?.try(&.as_a?)
      unless ancestors.empty?
        names = ancestors.map { |ancestor| ancestor["name"]?.try(&.as_s?) || "?" }
        lines << "**Ancestors:** #{names.join(", ")}"
      end
    end
  end

  private def self.format_source_location(lines : Array(String), node : JSON::Any)
    locs = node["locations"]?.try(&.as_a?)
    return if locs.nil? || locs.empty?

    loc = locs[0]
    filename = loc["filename"]?.try(&.as_s?) || ""
    lineno = loc["line_number"]?.try(&.as_i64?) || 0
    lines << "**Source:** #{filename}:#{lineno}"
    if url = loc["url"]?.try(&.as_s?)
      lines << "**Source URL:** #{url}"
    end
  end

  private def self.format_doc_section(lines : Array(String), node : JSON::Any)
    doc = node["doc"]?.try(&.as_s?)
    return if doc.nil? || doc.strip.empty?

    lines << ""
    lines << doc.strip
  end

  private def self.format_namespace_section(lines : Array(String), node : JSON::Any)
    namespace = node["namespace"]?
    return unless namespace

    name = namespace["full_name"]?.try(&.as_s?)
    return unless name

    lines << "**Namespace:** #{name}"
  end

  private def self.format_included_modules_section(lines : Array(String), node : JSON::Any)
    mods = node["included_modules"]?.try(&.as_a?)
    return if mods.nil? || mods.empty?

    names = mods.map { |mod| mod["full_name"]?.try(&.as_s?) || mod["name"]?.try(&.as_s?) || "?" }
    lines << "**Included Modules:** #{names.join(", ")}"
  end

  private def self.format_constants_section(lines : Array(String), node : JSON::Any)
    consts = node["constants"]?.try(&.as_a?)
    return if consts.nil? || consts.empty?

    lines << "\n### Constants"
    consts.each do |const|
      c_name = const["name"]?.try(&.as_s?) || "?"
      c_value = const["value"]?.try(&.as_s?) || ""
      lines << "  - #{c_name} = #{c_value}"
    end
  end

  private def self.format_constructors_section(lines : Array(String), node : JSON::Any)
    ctors = node["constructors"]?.try(&.as_a?)
    return if ctors.nil? || ctors.empty?

    lines << "\n### Constructors"
    format_method_list(lines, ctors)
  end

  private def self.format_methods_section(lines : Array(String), node : JSON::Any, key : String, heading : String)
    methods = node[key]?.try(&.as_a?)
    return if methods.nil? || methods.empty?

    lines << "\n#{heading}"
    format_method_list(lines, methods)
  end

  private def self.format_combined_methods_section(lines : Array(String), node : JSON::Any, keys : Array(String), heading : String)
    methods = [] of JSON::Any
    keys.each do |key|
      methods.concat(node[key]?.try(&.as_a?) || [] of JSON::Any)
    end
    return if methods.empty?

    lines << "\n#{heading}"
    format_method_list(lines, methods)
  end

  private def self.format_api_list(results : Array(CrystalDoc::MCP::TypeResult), namespace : String?, repo_str : String, version_str : String) : String
    if results.empty?
      scope = namespace && !namespace.empty? ? " under #{namespace}" : ""
      return "No documented types found#{scope} in #{repo_str} @ #{version_str}."
    end

    title = if namespace && !namespace.empty?
              "API for #{repo_str} @ #{version_str} under #{namespace}:\n"
            else
              "Top-level API for #{repo_str} @ #{version_str}:\n"
            end
    lines = [title]
    results.each do |result|
      lines << "  - **#{result.full_name}** (#{result.kind})"
      lines << "    URL: /#{result.repo}/#{result.version}/#{result.path}"
    end
    lines.join("\n")
  end

  private def self.format_method_details(method_details : CrystalDoc::MCP::MethodDetails, repo_str : String, version : String) : String
    lines = [] of String
    type_name = method_details.type_name
    method_kind = method_details.method_kind
    method = method_details.method
    method_name = method["name"]?.try(&.as_s?) || "?"

    method_label = method_name == "new" && method_kind == "constructor" ? ".new" : "##{method_name}"
    lines << "## #{type_name}#{method_label}"
    lines << "**Kind:** #{method_kind} method"
    lines << "**Repo:** #{repo_str} @ #{version}"
    lines << "**Owner:** #{type_name}"

    append_method_doc(lines, method)

    signature = format_method_signature(method)
    lines << ""
    lines << "**Signature:** `#{signature}`"

    append_method_source(lines, method)
    append_method_body(lines, method)

    lines.join("\n")
  end

  private def self.append_method_doc(lines : Array(String), method : JSON::Any) : Nil
    doc = method["doc"]?.try(&.as_s?)
    return if doc.nil? || doc.strip.empty?

    lines << ""
    lines << doc.strip
  end

  private def self.append_method_source(lines : Array(String), method : JSON::Any) : Nil
    return unless location = method["location"]?

    filename = location["filename"]?.try(&.as_s?) || ""
    lineno = location["line_number"]?.try(&.as_i64?) || 0
    lines << "**Source:** #{filename}:#{lineno}"
    if url = location["url"]?.try(&.as_s?)
      lines << "**Source URL:** #{url}"
    end
  end

  private def self.append_method_body(lines : Array(String), method : JSON::Any) : Nil
    return unless m_def = method["def"]?

    if visibility = m_def["visibility"]?.try(&.as_s?)
      lines << "**Visibility:** #{visibility}"
    end

    body = m_def["body"]?.try(&.as_s?)
    return if body.nil? || body.empty?

    lines << ""
    lines << "### Body"
    lines << "```crystal"
    lines << body
    lines << "```"
  end

  private def self.format_method_signature(method : JSON::Any) : String
    m_def = method["def"]?
    method_name = m_def.try(&.["name"]?.try(&.as_s?)) || method["name"]?.try(&.as_s?) || "?"

    args = m_def.try(&.["args"]?.try(&.as_a?)) || [] of JSON::Any
    arg_strs = args.map do |arg|
      a_name = arg["name"]?.try(&.as_s?) || "?"
      a_rest = arg["restriction"]?.try(&.as_s?)
      a_default = arg["default_value"]?.try(&.as_s?)

      arg_text = a_rest ? "#{a_name} : #{a_rest}" : a_name
      a_default ? "#{arg_text} = #{a_default}" : arg_text
    end

    sig = "#{method_name}(#{arg_strs.join(", ")})"
    if return_type = m_def.try(&.["return_type"]?.try(&.as_s?))
      sig += " : #{return_type}"
    end
    sig
  end

  private def self.format_nested_types_section(lines : Array(String), node : JSON::Any)
    sub_types = node["types"]?.try(&.as_a?)
    return if sub_types.nil? || sub_types.empty?

    lines << "\n### Nested Types"
    sub_types.each do |sub_type|
      t_name = sub_type["name"]?.try(&.as_s?) || "?"
      t_kind = sub_type["kind"]?.try(&.as_s?) || "?"
      lines << "  - **#{t_name}** (#{t_kind})"
    end
  end

  private def self.format_method_list(lines : Array(String), methods : Array(JSON::Any))
    methods.each do |_m|
      m_def = _m["def"]?
      next unless m_def

      m_name = m_def["name"]?.try(&.as_s?) || "?"
      m_vis = m_def["visibility"]?.try(&.as_s?) || "?"
      m_ret = m_def["return_type"]?.try(&.as_s?)

      args = m_def["args"]?.try(&.as_a?) || [] of JSON::Any
      arg_strs = args.map do |arg|
        a_name = arg["name"]?.try(&.as_s?) || "?"
        a_rest = arg["restriction"]?.try(&.as_s?)
        a_rest ? "#{a_name} : #{a_rest}" : a_name
      end

      sig = m_ret ? "#{m_name}(#{arg_strs.join(", ")}) : #{m_ret}" : "#{m_name}(#{arg_strs.join(", ")})"
      lines << "  - `#{sig}` (#{m_vis})"
    end
  end

  private def self.truncate_single_line(text : String, limit : Int32 = 120) : String
    one_line = text.gsub(/\s+/, " ").strip
    return one_line if one_line.size <= limit
    "#{one_line[0, limit - 3]}..."
  end
end
