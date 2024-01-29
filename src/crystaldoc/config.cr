struct CrystalDoc::Config
  include YAML::Serializable

  getter postgres_url : String
  getter github_api_key : String
  getter gitlab_api_key : String
end
