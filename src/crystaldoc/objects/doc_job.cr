class CrystalDoc::DocJob
  include DB::Serializable

  LATEST_PRIORITY     = 1000
  HISTORICAL_PRIORITY =  -10

  # Job metadata
  getter id : Int32
  getter priority : Int32
  getter job_age : PG::Interval

  # Job data
  getter source_url : String
  getter commit_id : String

  # Should only be called from a transaction
  def self.take(db : Queriable) : DocJob
    db.query_one(
      "DELETE FROM
         crystal_doc.doc_job
         USING (
          SELECT doc_job.id, doc_job.priority, age(now(), doc_job.queue_time) as job_age, sub.source_url, sub.commit_id
          FROM crystal_doc.doc_job
          INNER JOIN LATERAL (
              SELECT repo_version.id, repo_version.repo_id, repo_version.commit_id, repo.source_url
              FROM crystal_doc.repo_version
              LEFT JOIN crystal_doc.repo
              ON repo_version.repo_id = repo.id
              ) sub ON doc_job.version_id = sub.id
          ORDER BY doc_job.priority DESC, job_age DESC
          LIMIT 1 FOR UPDATE OF doc_job SKIP LOCKED
         ) taken_job
         WHERE taken_job.id = doc_job.id
         RETURNING taken_job.*", as: DocJob)
  end

  def self.select(db : Queriable, limit : Int32? = nil) : Array(DocJob)?
    db.query(
      "SELECT job.id, job.priority, age(now(), job.queue_time) as job_age, repo.source_url, repo_version.commit_id
         FROM crystal_doc.repo_version INNER JOIN crystal_doc.doc_job job
         ON repo_version.id = job.version_id
         INNER JOIN crystal_doc.repo
         ON repo.id = repo_version.repo_id
         ORDER BY job.priority DESC, job_age DESC LIMIT $1", limit) { |rs| CrystalDoc::DocJob.from_rs(rs) }
  end

  def self.create(db : Queriable, version_id : VersionId, priority : Int32) : Int32
    db.scalar(<<-SQL, version_id, priority).as(Int32)
      INSERT INTO crystal_doc.doc_job (version_id, priority)
      VALUES ($1, $2)
      RETURNING id
    SQL
  end
end
