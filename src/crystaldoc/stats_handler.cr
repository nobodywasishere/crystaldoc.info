require "./objects"

class CrystalDoc::StatsHandler < Kemal::Handler
  def initialize(@db : Queriable)
    super()
  end

  def call(context)
    unless (repo = CrystalDoc::Repo.from_request(@db, context.request)).nil?
      CrystalDoc::RepoStatistics.increment(@db, repo.id)
    end

    call_next context
  end
end
