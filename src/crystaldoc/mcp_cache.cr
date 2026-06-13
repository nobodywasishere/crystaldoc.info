require "json"

module CrystalDoc::MCP
  class DocCache
    private alias Entry = NamedTuple(data: JSON::Any, loaded_at: Time)
    private alias VersionsEntry = NamedTuple(data: Array(RepoVersionInfo), loaded_at: Time)

    @versions_cache : VersionsEntry?

    def initialize(@ttl : Time::Span = Time::Span.new(days: 1))
      @cache = {} of String => Entry
      @versions_cache = nil
      @mutex = Mutex.new
    end

    def get(service : String, user : String, project : String, version : String) : JSON::Any?
      key = "#{service}/#{user}/#{project}/#{version}"

      @mutex.synchronize do
        entry = @cache[key]?

        if entry
          if Time.utc - entry[:loaded_at] < @ttl
            return entry[:data]
          end
          @cache.delete(key)
        end

        path = Path.new("public", service, user, project, version, "index.json")
        if File.exists?(path)
          data = JSON.parse(File.read(path))
          @cache[key] = {data: data, loaded_at: Time.utc}
          return data
        end

        nil
      end
    end

    def search_methods(query : String, repo : String) : Array(MethodResult)
      results = [] of MethodResult
      q = query.downcase

      each_entry(repo, max_versions: 5) do |data, repo_path, version|
        walk_types(data) do |type|
          full_name = type["full_name"]?.try(&.as_s?) || next
          name = type["name"]?.try(&.as_s?) || next
          kind = type["kind"]?.try(&.as_s?) || ""

          each_method_entry(type) do |_m, method_kind|
            m_name = _m["name"]?.try(&.as_s?) || next
            if m_name.downcase.includes?(q)
              results << MethodResult.new(m_name, name, full_name, kind, repo_path, version, method_kind)
            end
          end
        end
      end

      results.first(50)
    end

    def search_constants(query : String, repo : String) : Array(ConstantResult)
      results = [] of ConstantResult
      q = query.downcase

      each_entry(repo, max_versions: 5) do |data, repo_path, version|
        walk_types(data) do |type|
          full_name = type["full_name"]?.try(&.as_s?) || next
          kind = type["kind"]?.try(&.as_s?) || ""

          (type["constants"]?.try(&.as_a?) || [] of JSON::Any).each do |const|
            const_name = const["name"]?.try(&.as_s?) || next
            const_value = const["value"]?.try(&.as_s?) || ""
            if const_name.downcase.includes?(q)
              results << ConstantResult.new(const_name, const_value, full_name, kind, repo_path, version)
            end
          end
        end
      end

      results.first(50)
    end

    def search_types(query : String, repo : String) : Array(TypeResult)
      results = [] of TypeResult
      q = query.downcase

      each_entry(repo, max_versions: 5) do |data, repo_path, version|
        walk_types(data) do |type|
          name = type["name"]?.try(&.as_s?) || next
          full_name = type["full_name"]?.try(&.as_s?) || next
          kind = type["kind"]?.try(&.as_s?) || ""
          path = type["path"]?.try(&.as_s?) || ""

          if name.downcase.includes?(q) || full_name.downcase.includes?(q)
            results << TypeResult.new(name, full_name, kind, repo_path, version, path)
          end
        end
      end

      results.first(50)
    end

    def list_api_types(service : String, user : String, project : String, version : String, namespace : String? = nil) : Array(TypeResult)
      data = get(service, user, project, version)
      return [] of TypeResult unless data

      program = data["program"]?
      return [] of TypeResult unless program

      types_arr = if namespace.nil? || namespace.empty?
                    program["types"]?.try(&.as_a?)
                  else
                    find_type_by_name(data, namespace).try &.["types"]?.try(&.as_a?)
                  end
      return [] of TypeResult unless types_arr

      repo_path = "#{service}/#{user}/#{project}"
      types_arr.compact_map do |type|
        name = type["name"]?.try(&.as_s?) || next
        full_name = type["full_name"]?.try(&.as_s?) || next
        kind = type["kind"]?.try(&.as_s?) || ""
        path = type["path"]?.try(&.as_s?) || ""
        TypeResult.new(name, full_name, kind, repo_path, version, path)
      end
    end

    def get_type(full_name : String, service : String, user : String, project : String, version : String) : JSON::Any?
      data = get(service, user, project, version)
      return unless data

      find_type_by_name(data, full_name)
    end

    def get_method(type_name : String, method_name : String, service : String, user : String, project : String, version : String, kind : String? = nil) : MethodDetails?
      type_node = get_type(type_name, service, user, project, version)
      return unless type_node

      each_method_entry(type_node) do |method, method_kind|
        next if method["name"]?.try(&.as_s?) != method_name
        next if kind && method_kind != kind

        return MethodDetails.new(type_name, method_kind, method)
      end

      nil
    end

    def list_repo_versions : Array(RepoVersionInfo)
      @mutex.synchronize do
        if (entry = @versions_cache) && (Time.utc - entry[:loaded_at] < @ttl)
          return entry[:data]
        end

        results = [] of RepoVersionInfo
        each_index_file do |service, user, project, version|
          results << RepoVersionInfo.new(service, user, project, version)
        end
        results = results.uniq { |info| {info.service, info.user, info.project, info.version} }

        @versions_cache = {data: results, loaded_at: Time.utc}
        results
      end
    end

    private def each_entry(repo : String? = nil, max_versions : Int32 = 0, & : JSON::Any, String, String ->)
      each_index_file(repo, max_versions: max_versions) do |service, user, project, version|
        repo_path = "#{service}/#{user}/#{project}"
        data = get(service, user, project, version)
        yield data, repo_path, version if data
      end
    end

    private def each_index_file(repo : String? = nil, max_versions : Int32 = 0, & : String, String, String, String ->)
      if repo
        parts = repo.split("/")
        return unless parts.size == 3 && parts.none?(&.empty?)
        pattern = Path.new("public", parts[0], parts[1], parts[2], "*", "index.json")
      else
        pattern = Path.new("public", "*", "*", "*", "*", "index.json")
      end

      paths = Dir.glob(pattern.to_s)
      if max_versions > 0
        paths.sort! do |a, b|
          a_parts = a.split("/")
          b_parts = b.split("/")
          b_parts[-2] <=> a_parts[-2]
        end
        paths = paths.first(max_versions)
      end

      paths.each do |filepath|
        parts = filepath.split("/")
        next unless parts.size >= 6
        service, user, project, version = parts[-5], parts[-4], parts[-3], parts[-2]
        yield service, user, project, version
      end
    end

    private def walk_types(data : JSON::Any, &block : JSON::Any ->)
      program = data["program"]?
      return unless program

      types_arr = program["types"]?.try(&.as_a?)
      return unless types_arr

      types_arr.each do |type|
        walk_types_inner(type, &block)
      end
    end

    private def walk_types_inner(node : JSON::Any, &block : JSON::Any ->)
      yield node

      sub = node["types"]?.try(&.as_a?)
      return unless sub

      sub.each do |type|
        walk_types_inner(type, &block)
      end
    end

    private def find_type_by_name(data : JSON::Any, full_name : String) : JSON::Any?
      program = data["program"]?
      return unless program

      types_arr = program["types"]?.try(&.as_a?)
      return unless types_arr

      types_arr.each do |type|
        result = find_type_inner(type, full_name)
        return result if result
      end

      nil
    end

    private def find_type_inner(node : JSON::Any, full_name : String) : JSON::Any?
      if node["full_name"]?.try(&.as_s?) == full_name
        return node
      end

      sub = node["types"]?.try(&.as_a?)
      return unless sub

      sub.each do |type|
        result = find_type_inner(type, full_name)
        return result if result
      end

      nil
    end

    private def each_method_entry(type : JSON::Any, & : JSON::Any, String ->)
      {"constructors" => "constructor", "instance_methods" => "instance", "class_methods" => "class", "methods" => "class"}.each do |key, kind|
        (type[key]?.try(&.as_a?) || [] of JSON::Any).each do |method|
          yield method, kind
        end
      end
    end
  end

  struct MethodResult
    getter method_name : String
    getter type_name : String
    getter full_name : String
    getter kind : String
    getter repo : String
    getter version : String
    getter method_kind : String

    def initialize(@method_name : String, @type_name : String, @full_name : String, @kind : String, @repo : String, @version : String, @method_kind : String)
    end
  end

  struct MethodDetails
    getter type_name : String
    getter method_kind : String
    getter method : JSON::Any

    def initialize(@type_name : String, @method_kind : String, @method : JSON::Any)
    end
  end

  struct ConstantResult
    getter name : String
    getter value : String
    getter full_name : String
    getter kind : String
    getter repo : String
    getter version : String

    def initialize(@name : String, @value : String, @full_name : String, @kind : String, @repo : String, @version : String)
    end
  end

  struct TypeResult
    include JSON::Serializable

    getter name : String
    getter full_name : String
    getter kind : String
    getter repo : String
    getter version : String
    getter path : String

    def initialize(@name : String, @full_name : String, @kind : String, @repo : String, @version : String, @path : String)
    end
  end

  struct RepoVersionInfo
    include JSON::Serializable

    getter service : String
    getter user : String
    getter project : String
    getter version : String

    def initialize(@service : String, @user : String, @project : String, @version : String)
    end

    def repo_path
      "#{service}/#{user}/#{project}"
    end
  end
end
