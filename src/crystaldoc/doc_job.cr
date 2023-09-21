require "db"
require "pg"

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
  def self.take(db : Queriable) : Array(DocJob)
    db.query_all(<<-SQL, as: {DocJob})
      DELETE
      FROM crystal_doc.doc_job
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
      RETURNING taken_job.*;
    SQL
  end

  def self.select(db : Queriable, limit : Int32) : Array(DocJob)?
    db.query_all(<<-SQL, limit, as: {DocJob})
      SELECT job.id, job.priority, age(now(), job.queue_time) as job_age, repo.source_url, repo_version.commit_id
      FROM crystal_doc.repo_version
      INNER JOIN crystal_doc.doc_job job
        ON repo_version.id = job.version_id
      INNER JOIN crystal_doc.repo
        ON repo.id = repo_version.repo_id
      ORDER BY job.priority DESC, job_age DESC
      LIMIT $1
    SQL
  end

  def self.in_queue?(db : Queriable, service : String, username : String, project_name : String, version : String) : Bool
    db.query_one(<<-SQL, service, username, project_name, version, as: Bool)
      SELECT EXISTS (
        SELECT 1
        FROM crystal_doc.doc_job
        INNER JOIN crystal_doc.repo_version
          ON repo_version.id = doc_job.version_id
        INNER JOIN crystal_doc.repo
          ON repo.id = repo_version.repo_id
        WHERE repo.service = $1 AND repo.username = $2 AND repo.project_name = $3 AND repo_version.commit_id = $4
      )
    SQL
  end

  def self.in_queue?(db : Queriable, version_id : Int32) : Bool
    db.query_one(<<-SQL, version_id, as: Bool)
      SELECT EXISTS (
        SELECT 1
        FROM crystal_doc.doc_job
        WHERE doc_job.version_id = $1
      )
    SQL
  end

  def self.count(db : Queriable) : Int64
    db.scalar(<<-SQL).as(Int64)
      SELECT n_live_tup
      FROM pg_stat_user_tables
      WHERE relname = 'doc_job';
    SQL
  end
end
