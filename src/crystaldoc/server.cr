require "kemal"
require "db"
require "pg"
require "random/secure"

serve_static({"gzip" => true, "dir_listing" => false})

# Export main CSS file

Dir.mkdir_p("public/css", 0o744)
File.write "public/css/style.css", CrystalDoc::Views::StyleTemplate.new

# ── MCP rate limiter ─────────────────────────────────────────────────
RATE_LIMITER = CrystalDoc::RateLimiter.new(max_tokens: 60.0, refill_rate: 1.0)

private def client_ip(env) : String
  env.request.headers["X-Forwarded-For"]?.try(&.split(",").first.strip) ||
    env.request.remote_address.try(&.to_s) ||
    "unknown"
end

get "/" do
  render "src/views/main.ecr", "src/views/layout.ecr"
end

get "/:serv/:user/:proj" do |env|
  path = env.request.path
  unless path.ends_with? "/"
    path += "/"
  end

  env.redirect "#{path}latest"
end

get "/:serv/:user/:proj/latest" do |env|
  unless CrystalDoc::Queries.repo_exists_and_valid(REPO_DB, env.params.url["serv"], env.params.url["user"], env.params.url["proj"])
    env.response.status_code = 404
    next
  end

  latest_version = CrystalDoc::Queries.latest_version(REPO_DB,
    env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
  )

  if latest_version.nil?
    env.response.status_code = 404
  else
    env.redirect "./#{latest_version}/index.html"
  end
end

get "/:serv/:user/:proj/latest/*path" do |env|
  unless CrystalDoc::Queries.repo_exists_and_valid(REPO_DB, env.params.url["serv"], env.params.url["user"], env.params.url["proj"])
    env.response.status_code = 404
    next
  end

  latest_version = CrystalDoc::Queries.latest_version(REPO_DB,
    env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
  )

  if latest_version.nil?
    env.response.status_code = 404
  else
    env.redirect "/#{env.params.url["serv"]}/#{env.params.url["user"]}/#{env.params.url["proj"]}/#{latest_version}/#{env.params.url["path"]? || "index.html"}"
  end
end

get "/:serv/:user/:proj/:version" do |env|
  path = env.request.path
  unless path.ends_with? "/"
    path += "/"
  end

  env.redirect "#{path}index.html"
end

get "/:serv/:user/:proj/versions.json" do |env|
  CrystalDoc::Queries.versions_json(REPO_DB,
    env.params.url["serv"], env.params.url["user"], env.params.url["proj"]
  )
end

get "/random" do |env|
  repo = CrystalDoc::Queries.random_repo(REPO_DB)
  env.redirect repo.path
end

post "/search" do |env|
  query = env.params.body["q"]
  if query.includes? "/"
    user, proj = query.split("/")[0..1] # ameba:disable Lint/UselessAssign
    distinct = true                     # ameba:disable Lint/UselessAssign
  else
    user = query     # ameba:disable Lint/UselessAssign
    proj = query     # ameba:disable Lint/UselessAssign
    distinct = false # ameba:disable Lint/UselessAssign
  end
  render "src/views/search_results.ecr" unless query == ""
end

get "/jobs_queue" do
  render "src/views/jobs_queue_head.ecr", "src/views/layout.ecr"
end

post "/jobs_queue" do
  limit = 20 # ameba:disable Lint/UselessAssign
  render "src/views/jobs_queue_body.ecr"
end

post "/new_repository" do |env|
  url = env.params.body["url"].as(String)

  if CrystalDoc::Queries.repo_exists(REPO_DB, url)
    "Repository exists"
  else
    vcs = CrystalDoc::VCS.new(url)
    vcs.parse(REPO_DB)
  end
rescue ex
  Log.error { "NewRepo Exception: #{ex.inspect}\n  #{ex.backtrace.join("\n  ")}" }
end

# ── MCP (Model Context Protocol) ────────────────────────────────────
# SSE transport — required by MCP spec for real-time communication
#
# The MCP SSE transport works as follows:
#   1. Client opens an SSE connection to GET /mcp
#   2. Server sends the endpoint the client should POST to
#   3. Client POSTs JSON-RPC 2.0 messages to that endpoint
#   4. Server writes JSON-RPC responses as SSE "message" events
#
MCP_CHANNELS       = {} of String => Channel(String)
MCP_CHANNELS_MUTEX = Mutex.new

private def register_mcp_session : {String, Channel(String)}
  session_id = Random::Secure.hex(16)
  channel = Channel(String).new(32)
  MCP_CHANNELS_MUTEX.synchronize do
    MCP_CHANNELS[session_id] = channel
  end
  {session_id, channel}
end

private def unregister_mcp_session(session_id : String) : Nil
  MCP_CHANNELS_MUTEX.synchronize do
    MCP_CHANNELS.delete(session_id)
  end
end

private def mcp_session_channel(session_id : String?) : Channel(String)?
  return unless session_id

  MCP_CHANNELS_MUTEX.synchronize do
    MCP_CHANNELS[session_id]?
  end
end

get "/mcp" do |env|
  halt env, status_code: 429, response: "Rate limit exceeded\n" unless RATE_LIMITER.allow?(client_ip(env))

  env.response.content_type = "text/event-stream"
  env.response.headers["Cache-Control"] = "no-cache"
  env.response.headers["Connection"] = "keep-alive"
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type"

  session_id, channel = register_mcp_session

  env.response.puts "event: endpoint"
  env.response.puts "data: /mcp?session_id=#{session_id}"
  env.response.puts ""
  env.response.flush

  loop do
    select
    when msg = channel.receive
      env.response.puts "event: message"
      env.response.puts "data: #{msg}"
      env.response.puts ""
    when timeout(30.seconds)
      env.response.puts ": keepalive"
      env.response.puts ""
    end
    env.response.flush
  end
rescue IO::Error
  # client disconnected
ensure
  unregister_mcp_session(session_id) if session_id
end

# POST handler — receives JSON-RPC 2.0 messages
post "/mcp" do |env|
  halt env, status_code: 429, response: "Rate limit exceeded\n" unless RATE_LIMITER.allow?(client_ip(env))

  env.response.content_type = "application/json"
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type"

  body = env.request.body.try(&.gets_to_end) || ""
  session_id = env.request.query_params["session_id"]?
  channel = mcp_session_channel(session_id)

  unless channel
    status_code, response = CrystalDoc::MCP.handle_streamable_http(body, REPO_DB)
    env.response.status_code = status_code
    next response
  end

  request = JSON.parse(body)

  unless request.raw.is_a?(Hash)
    halt env, status_code: 400, response: CrystalDoc::MCP.parse_error_response
  end

  response = CrystalDoc::MCP.handle(request, REPO_DB)
  channel.send(response) unless response.empty?
  env.response.status_code = 202
  ""
rescue JSON::ParseException
  error = CrystalDoc::MCP.parse_error_response
  channel.try(&.send(error))
  env.response.status_code = 202
  ""
end

# CORS preflight for MCP
options "/mcp" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type"
  env.response.headers["Access-Control-Max-Age"] = "86400"
  "OK"
end

error 404 do |env|
  title = "" # ameba:disable Lint/UselessAssign
  msg = ""   # ameba:disable Lint/UselessAssign

  unless /(?:\/~?[a-zA-Z0-9\.\-_]+){4,}/.match(env.request.path)
    title = "This page doesn't exist" # ameba:disable Lint/UselessAssign
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  service, user, proj, version = env.request.path.split("/")[1..4]

  # Check if it's a valid repo / version
  unless CrystalDoc::Queries.repo_exists(REPO_DB, service, user, proj)
    title = "Repo doesn't exist" # ameba:disable Lint/UselessAssign
    msg = <<-MSG                 # ameba:disable Lint/UselessAssign
      The repo '#{service}/#{user}/#{proj}' doesn't exist. You can add it by submitting the URL <a href='https://crystaldoc.info/#add-a-shard'>here</a>.
      MSG

    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  if version == "latest"
    title = "All repo versions failed to build docs"                                                # ameba:disable Lint/UselessAssign
    msg = "All of the versions for repo '#{service}/#{user}/#{proj}' failed to build documentation" # ameba:disable Lint/UselessAssign
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  unless CrystalDoc::Queries.repo_version_exists(REPO_DB, service, user, proj, version)
    title = "Version doesn't exist"                                                      # ameba:disable Lint/UselessAssign
    msg = "The version '#{version}' for repo '#{service}/#{user}/#{proj}' doesn't exist" # ameba:disable Lint/UselessAssign
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  # Check if doc generation is queued
  if CrystalDoc::DocJob.in_queue?(REPO_DB, service, user, proj, version)
    title = "Version in build queue"                                                             # ameba:disable Lint/UselessAssign
    msg = "The version '#{version}' for repo '#{service}/#{user}/#{proj}' is in the build queue" # ameba:disable Lint/UselessAssign
    next render "src/views/404.ecr", "src/views/layout.ecr"
  end

  title = "File does not exist" # ameba:disable Lint/UselessAssign

  # Shouldn't end up here
  render "src/views/404.ecr", "src/views/layout.ecr"
end
