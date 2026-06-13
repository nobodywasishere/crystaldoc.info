require "../spec_helper"

# Helper: parse a JSON-RPC response and return the parsed JSON
private def parse_rpc(json_str : String) : JSON::Any
  JSON.parse(json_str)
end

# Create a minimal valid index.json fixture in a temp directory
private def with_fixture_repo(&)
  dir = File.join(Dir.tempdir, "crystaldoc_mcp_spec_#{Random.rand(1_000_000)}")
  version_dir = File.join(dir, "public", "github", "testuser", "testproject", "v1.0.0")
  Dir.mkdir_p(version_dir)
  File.write(File.join(version_dir, "index.json"), <<-'JSON')
    {
      "program": {
        "types": [
          {
            "name": "Foo",
            "full_name": "Foo",
            "kind": "class",
            "path": "Foo.html",
            "doc": "Foo is the main entry point.",
            "locations": [
              { "filename": "src/foo.cr", "line_number": 1, "url": "https://example.test/src/foo.cr#L1" }
            ],
            "namespace": {
              "name": "TestProject",
              "full_name": "TestProject"
            },
            "included_modules": [
              { "name": "JSON::Serializable", "full_name": "JSON::Serializable" }
            ],
            "constants": [
              { "name": "DEFAULT_LIMIT", "value": "10" }
            ],
            "constructors": [
              {
                "name": "new",
                "location": { "filename": "src/foo.cr", "line_number": 2, "url": "https://example.test/src/foo.cr#L2" },
                "def": { "name": "new", "visibility": "public", "args": [{ "name": "name", "restriction": "String" }], "body": "@name = name" }
              }
            ],
            "instance_methods": [
              {
                "name": "bar",
                "doc": "Return the configured limit.",
                "location": { "filename": "src/foo.cr", "line_number": 6, "url": "https://example.test/src/foo.cr#L6" },
                "def": { "name": "bar", "visibility": "public", "return_type": "Int32", "args": [], "body": "DEFAULT_LIMIT" }
              }
            ],
            "class_methods": [
              {
                "name": "build",
                "location": { "filename": "src/foo.cr", "line_number": 10, "url": "https://example.test/src/foo.cr#L10" },
                "def": { "name": "build", "visibility": "public", "return_type": "Foo", "args": [], "body": "new(\"built\")" }
              }
            ],
            "types": [
              {
                "name": "Builder",
                "full_name": "Foo::Builder",
                "kind": "class",
                "path": "Foo/Builder.html"
              },
              {
                "name": "Parser",
                "full_name": "Foo::Parser",
                "kind": "module",
                "path": "Foo/Parser.html"
              }
            ]
          }
        ]
      },
      "body": "# README\\n\\nHello world"
    }
    JSON

  old_public = Dir.current
  Dir.cd(dir)
  yield
ensure
  Dir.cd(old_public) if old_public
  Process.run("rm", ["-rf", dir]) if dir
end

# ── RateLimiter ──────────────────────────────────────────────────────

describe CrystalDoc::RateLimiter do
  describe "#allow?" do
    it "allows requests within the rate limit" do
      limiter = CrystalDoc::RateLimiter.new(max_tokens: 5.0, refill_rate: 10.0)
      5.times { limiter.allow?("test").should be_true }
    end

    it "denies requests when rate limit is exhausted" do
      limiter = CrystalDoc::RateLimiter.new(max_tokens: 3.0, refill_rate: 10.0)
      3.times { limiter.allow?("test") }
      limiter.allow?("test").should be_false
    end

    it "tracks separate buckets per key" do
      limiter = CrystalDoc::RateLimiter.new(max_tokens: 2.0, refill_rate: 10.0)
      2.times { limiter.allow?("alice") }
      limiter.allow?("bob").should be_true
      limiter.allow?("alice").should be_false
    end

    it "refills tokens over time" do
      limiter = CrystalDoc::RateLimiter.new(max_tokens: 1.0, refill_rate: 60.0)
      limiter.allow?("test").should be_true  # consume the only token
      limiter.allow?("test").should be_false # should be denied immediately

      sleep(50.milliseconds)
      limiter.allow?("test").should be_true
    end

    it "does not exceed max_tokens" do
      limiter = CrystalDoc::RateLimiter.new(max_tokens: 10.0, refill_rate: 100.0)
      sleep(200.milliseconds)
      10.times { limiter.allow?("test").should be_true }
      limiter.allow?("test").should be_false
    end
  end
end

# ── JSON-RPC helpers ─────────────────────────────────────────────────

describe CrystalDoc::MCP do
  describe ".parse_error_response" do
    it "returns a valid JSON-RPC 2.0 parse error" do
      response = parse_rpc(CrystalDoc::MCP.parse_error_response)
      response["jsonrpc"].should eq("2.0")
      response["error"]["code"].should eq(-32_700)
      response["error"]["message"].should eq("Parse error")
      response["id"].raw.should be_nil
    end
  end

  describe ".handle" do
    db = uninitialized DB::Database

    it "responds to ping" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"ping"}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["jsonrpc"].should eq("2.0")
      response["id"].should eq(1)
      response["result"].should be_a(JSON::Any)
    end

    it "responds to initialize" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"initialize"}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["jsonrpc"].should eq("2.0")
      response["id"].should eq(1)
      response["result"]["protocolVersion"].should eq("2024-11-05")
      response["result"]["capabilities"]["tools"]["listChanged"].should be_false
      response["result"]["capabilities"]["resources"]["listChanged"].should be_false
      response["result"]["serverInfo"]["name"].should eq("crystaldoc-mcp")
    end

    it "handles notifications/initialized (no response)" do
      request = JSON.parse(%({"jsonrpc":"2.0","method":"notifications/initialized"}))
      CrystalDoc::MCP.handle(request, db).should eq("")
    end

    it "responds to tools/list" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/list"}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["jsonrpc"].should eq("2.0")
      response["id"].should eq(1)
      tools = response["result"]["tools"].as_a
      tool_names = tools.map(&.["name"].as_s)
      tool_names.should contain("search_documentation")
      tool_names.should contain("search_types")
      tool_names.should contain("list_repos")
      tool_names.should contain("list_versions")
      tool_names.should contain("get_readme")
      tool_names.should contain("search_methods")
      tool_names.should contain("search_constants")
      tool_names.should contain("get_method_details")
      tool_names.should contain("list_api")
      tools.size.should eq(9)
    end

    it "rejects malformed repo values for search_documentation" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_documentation","arguments":{"query":"Foo","repo":"github/testuser"}}}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["error"]["code"].should eq(-32_602)
      response["error"]["message"].should eq("Invalid repo format: expected service/user/project")
    end

    it "rejects malformed repo values for search_methods" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_methods","arguments":{"query":"bar","repo":"github/testuser"}}}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["error"]["code"].should eq(-32_602)
      response["error"]["message"].should eq("Invalid repo format: expected service/user/project")
    end

    it "rejects malformed repo values for get_readme" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_readme","arguments":{"repo":"github/testuser"}}}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["error"]["code"].should eq(-32_602)
      response["error"]["message"].should eq("Invalid repo format: expected service/user/project")
    end

    it "rejects malformed repo values for search_constants" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_constants","arguments":{"query":"DEFAULT","repo":"github/testuser"}}}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["error"]["code"].should eq(-32_602)
      response["error"]["message"].should eq("Invalid repo format: expected service/user/project")
    end

    it "returns error for missing method" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":1,"params":{}}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["error"]["code"].should eq(-32_600)
      response["error"]["message"].should eq("Invalid Request: no method")
      response["id"].should eq(1)
    end

    it "returns error for unknown method" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"nonsense"}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["error"]["code"].should eq(-32_601)
      response["error"]["message"].should eq("Method not found: nonsense")
      response["id"].should eq(1)
    end

    it "preserves string IDs in responses" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":"req-1","method":"ping"}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["id"].should eq("req-1")
    end

    it "preserves numeric IDs in responses" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":42,"method":"ping"}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["id"].should eq(42)
    end

    it "handles null ID" do
      request = JSON.parse(%({"jsonrpc":"2.0","id":null,"method":"ping"}))
      response = parse_rpc(CrystalDoc::MCP.handle(request, db))
      response["id"].raw.should be_nil
    end
  end

  describe ".handle_streamable_http" do
    db = uninitialized DB::Database

    it "returns initialize responses inline for streamable HTTP clients" do
      status, body = CrystalDoc::MCP.handle_streamable_http(%({"jsonrpc":"2.0","id":1,"method":"initialize"}), db)
      status.should eq(200)

      response = parse_rpc(body)
      response["jsonrpc"].should eq("2.0")
      response["id"].should eq(1)
      response["result"]["protocolVersion"].should eq("2024-11-05")
    end

    it "returns 202 with no body for notifications" do
      status, body = CrystalDoc::MCP.handle_streamable_http(%({"jsonrpc":"2.0","method":"notifications/initialized"}), db)
      status.should eq(202)
      body.should eq("")
    end

    it "returns a JSON parse error body for invalid JSON" do
      status, body = CrystalDoc::MCP.handle_streamable_http("not json", db)
      status.should eq(400)

      response = parse_rpc(body)
      response["jsonrpc"].should eq("2.0")
      response["error"]["code"].should eq(-32_700)
    end
  end
end

# ── DocCache ─────────────────────────────────────────────────────────

describe CrystalDoc::MCP::DocCache do
  describe "#get" do
    it "returns parsed JSON for an existing version" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        data = cache.get("github", "testuser", "testproject", "v1.0.0")
        data.should_not be_nil
        data.as(JSON::Any)["body"].should eq("# README\\n\\nHello world")
      end
    end

    it "returns nil for a non-existent version" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        cache.get("github", "testuser", "testproject", "v9.9.9").should be_nil
      end
    end

    it "caches data so subsequent calls avoid filesystem reads" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        first = cache.get("github", "testuser", "testproject", "v1.0.0")
        first.should_not be_nil

        File.delete(File.join("public", "github", "testuser", "testproject", "v1.0.0", "index.json"))
        second = cache.get("github", "testuser", "testproject", "v1.0.0")
        second.should_not be_nil
        second.as(JSON::Any)["body"].should eq("# README\\n\\nHello world")
      end
    end

    it "returns nil for non-existent repo" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        cache.get("github", "nobody", "nothing", "v1.0.0").should be_nil
      end
    end
  end

  describe "#search_types" do
    it "finds types by name substring" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.search_types("Foo", "github/testuser/testproject")
        results.size.should be >= 1
        names = results.map(&.name)
        names.should contain("Foo")
      end
    end

    it "returns empty array for no matches" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.search_types("NonExistentType", "github/testuser/testproject")
        results.should be_empty
      end
    end

    it "is case-insensitive" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.search_types("foo", "github/testuser/testproject")
        results.size.should be >= 1
      end
    end

    it "does not widen malformed repo filters into wildcard scans" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.search_types("Foo", "github/testuser")
        results.should be_empty
      end
    end
  end

  describe "#search_methods" do
    it "finds methods by name substring" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.search_methods("bar", "github/testuser/testproject")
        results.size.should be >= 1
        results.first.method_name.should eq("bar")
      end
    end

    it "finds class methods by name substring" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.search_methods("build", "github/testuser/testproject")
        results.size.should eq(1)
        results.first.method_kind.should eq("class")
      end
    end

    it "returns empty array for no matches" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.search_methods("nope", "github/testuser/testproject")
        results.should be_empty
      end
    end

    it "does not widen malformed repo filters into wildcard scans" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.search_methods("bar", "github/testuser")
        results.should be_empty
      end
    end
  end

  describe "#search_constants" do
    it "finds constants by name substring" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.search_constants("DEFAULT", "github/testuser/testproject")
        results.size.should eq(1)
        results.first.name.should eq("DEFAULT_LIMIT")
      end
    end

    it "returns empty array for no matches" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.search_constants("MISSING", "github/testuser/testproject")
        results.should be_empty
      end
    end
  end

  describe "#get_type" do
    it "finds a type by full_name" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        type = cache.get_type("Foo", "github", "testuser", "testproject", "v1.0.0")
        type.should_not be_nil
        type.as(JSON::Any)["name"].should eq("Foo")
      end
    end

    it "returns nil for a non-existent type" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        type = cache.get_type("Bar", "github", "testuser", "testproject", "v1.0.0")
        type.should be_nil
      end
    end
  end

  describe "#get_method" do
    it "finds an instance method with body and location" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        method = cache.get_method("Foo", "bar", "github", "testuser", "testproject", "v1.0.0")
        method.should_not be_nil
        if method
          method.method_kind.should eq("instance")
          method.method["location"]["line_number"].should eq(6)
          method.method["def"]["body"].should eq("DEFAULT_LIMIT")
        end
      end
    end

    it "filters by method kind" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        cache.get_method("Foo", "build", "github", "testuser", "testproject", "v1.0.0", "instance").should be_nil
        method = cache.get_method("Foo", "build", "github", "testuser", "testproject", "v1.0.0", "class")
        method.should_not be_nil
        method.try(&.method_kind).should eq("class")
      end
    end
  end

  describe "#list_api_types" do
    it "lists top-level api types by default" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.list_api_types("github", "testuser", "testproject", "v1.0.0")
        results.map(&.full_name).should eq(["Foo"])
      end
    end

    it "lists nested api types for a namespace" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.list_api_types("github", "testuser", "testproject", "v1.0.0", "Foo")
        results.map(&.full_name).should eq(["Foo::Builder", "Foo::Parser"])
      end
    end

    it "returns empty array for an unknown namespace" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        results = cache.list_api_types("github", "testuser", "testproject", "v1.0.0", "Missing")
        results.should be_empty
      end
    end
  end

  describe "#list_repo_versions" do
    it "lists all repo versions from the filesystem" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        versions = cache.list_repo_versions
        versions.size.should be >= 1
        versions.any? { |v| v.service == "github" && v.user == "testuser" && v.project == "testproject" && v.version == "v1.0.0" }.should be_true
      end
    end

    it "caches the version list" do
      with_fixture_repo do
        cache = CrystalDoc::MCP::DocCache.new
        first = cache.list_repo_versions

        # Create another version directory
        Dir.mkdir_p(File.join("public", "github", "testuser", "testproject", "v2.0.0"))
        File.write(File.join("public", "github", "testuser", "testproject", "v2.0.0", "index.json"), "{\"program\":{\"types\":[]}}")

        second = cache.list_repo_versions
        second.size.should eq(first.size)
      end
    end
  end

  describe "tool output" do
    db = uninitialized DB::Database

    it "includes constructors and source urls in search_types output" do
      with_fixture_repo do
        request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_types","arguments":{"full_name":"Foo","repo":"github/testuser/testproject","version":"v1.0.0"}}}))
        response = parse_rpc(CrystalDoc::MCP.handle(request, db))
        text = response["result"]["content"][0]["text"].as_s
        text.should contain("Foo is the main entry point.")
        text.should contain("### Constructors")
        text.should contain("**Source URL:** https://example.test/src/foo.cr#L1")
      end
    end

    it "returns detailed method output including source and body" do
      with_fixture_repo do
        request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_method_details","arguments":{"repo":"github/testuser/testproject","version":"v1.0.0","type_name":"Foo","method_name":"bar"}}}))
        response = parse_rpc(CrystalDoc::MCP.handle(request, db))
        text = response["result"]["content"][0]["text"].as_s
        text.should contain("## Foo#bar")
        text.should contain("**Source:** src/foo.cr:6")
        text.should contain("**Source URL:** https://example.test/src/foo.cr#L6")
        text.should contain("**Signature:** `bar() : Int32`")
        text.should contain("```crystal")
        text.should contain("DEFAULT_LIMIT")
      end
    end

    it "lists top-level api types" do
      with_fixture_repo do
        request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_api","arguments":{"repo":"github/testuser/testproject","version":"v1.0.0"}}}))
        response = parse_rpc(CrystalDoc::MCP.handle(request, db))
        text = response["result"]["content"][0]["text"].as_s
        text.should contain("Top-level API for github/testuser/testproject @ v1.0.0:")
        text.should contain("**Foo** (class)")
      end
    end

    it "lists scoped api types for a namespace" do
      with_fixture_repo do
        request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_api","arguments":{"repo":"github/testuser/testproject","version":"v1.0.0","namespace":"Foo"}}}))
        response = parse_rpc(CrystalDoc::MCP.handle(request, db))
        text = response["result"]["content"][0]["text"].as_s
        text.should contain("API for github/testuser/testproject @ v1.0.0 under Foo:")
        text.should contain("**Foo::Builder** (class)")
        text.should contain("**Foo::Parser** (module)")
      end
    end

    it "returns README content through get_readme" do
      with_fixture_repo do
        request = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_readme","arguments":{"repo":"github/testuser/testproject","version":"v1.0.0"}}}))
        response = parse_rpc(CrystalDoc::MCP.handle(request, db))
        text = response["result"]["content"][0]["text"].as_s
        text.should eq("# README\\n\\nHello world")
      end
    end
  end
end
