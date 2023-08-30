class CrystalDoc::RepoStatistics
  include DB::Serializable

  property id : Int32
  property repo_id : Int32
  property count : Int32

  def self.increment(db : Queriable, repo_id : RepoId)
    db.exec(<<-SQL, repo_id)
      INSERT INTO crystal_doc.repo_statistics(repo_id, count)
      VALUES ($1, 1)
      ON CONFLICT (repo_id) DO UPDATE SET count = crystal_doc.repo_statistics.count + 1;
    SQL
  end
end
