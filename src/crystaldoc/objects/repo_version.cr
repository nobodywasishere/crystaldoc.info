class CrystalDoc::RepoVersion
  include DB::Serializable

  getter id : Int32
  getter repo_id : Int32
  getter commit_id : String
  getter nightly : Bool

  def initialize(@id : Int32, @repo_id : Int32, @commit_id : String, @nightly : Bool)
  end

  def self.find(db : Queriable, repo_id : Int32, commit_id : String) : RepoVersion
    db.query_one(<<-SQL, repo_id, commit_id, as: RepoVersion)
      SELECT * FROM crystal_doc.repo_version WHERE repo_id = $1 AND commit_id = $2
    SQL
  end

  def self.create(db : Queriable, repo_id : RepoId, commit_id : String, nightly : Bool = false) : VersionId
    db.scalar(<<-SQL, repo_id, commit_id, nightly).as(Int32)
      INSERT INTO crystal_doc.repo_version (repo_id, commit_id, nightly)
      VALUES ($1, $2, $3)
      RETURNING id
    SQL
  end

  def self.latest(db : Queriable, repo_id : RepoId) : RepoVersion?
    db.query_one(<<-SQL, repo_id, as: RepoVersion)
      SELECT repo_version.id, repo_version.repo_id, repo_version.commit_id, repo_version.nightly
      FROM crystal_doc.repo_version INNER JOIN crystal_doc.repo_latest_version
      ON repo_version.id = repo_latest_version.latest_version
      WHERE repo_latest_version.repo_id = $1
    SQL
  end

  def self.latest(db : Queriable, service : String, username : String, project_name : String) : RepoVersion?
    db.query_one(<<-SQL, service, username, project_name, as: RepoVersion)
      SELECT repo_version.id, repo_version.repo_id, repo_version.commit_id, repo_version.nightly
      FROM crystal_doc.repo_version INNER JOIN crystal_doc.repo_latest_version
      ON repo_version.id = repo_latest_version.latest_version
      INNER JOIN crystal_doc.repo
      ON repo.id = repo_latest_version.repo_id
      WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3
    SQL
  end

  def self.all(db : Queriable, service : String, username : String, project_name : String) : Array(RepoVersion)?
    db.query(<<-SQL, service, username, project_name) { |rs| CrystalDoc::RepoVersion.from_rs(rs) }
      SELECT repo_version.id, repo_version.repo_id, repo_version.commit_id, repo_version.nightly
      FROM crystal_doc.repo_version
      WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3
    SQL
  end

  def self.all(db : Queriable, repo_id : RepoId) : Array(RepoVersion)?
    db.query(<<-SQL, id) { |rs| CrystalDoc::RepoVersion.from_rs(rs) }
      SELECT repo_version.id, repo_version.repo_id, repo_version.commit_id, repo_version.nightly
      FROM crystal_doc.repo_version
      WHERE repo_id = $1
    SQL
  end
end
