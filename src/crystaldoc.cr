require "kemal"

module CrystalDoc
  VERSION = "0.1.0"

  GIT_WEBSITES = {
    "github" => "https://github.com",
    "gitlab" => "https://gitlab.com"
  }
end

require "./crystaldoc/repository"
require "./crystaldoc/worker"
require "./crystaldoc/server"

Kemal.run
