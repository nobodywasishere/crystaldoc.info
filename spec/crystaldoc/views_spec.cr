require "../spec_helper"

describe CrystalDoc::Views do
  describe CrystalDoc::Views::StyleTemplate do
    it "renders to a string" do
      CrystalDoc::Views::StyleTemplate.new.to_s.should be_a(String)
    end
  end

  describe CrystalDoc::Views::BuildFailureTemplate do
    it "renders to a string" do
      CrystalDoc::Views::BuildFailureTemplate.new("https://source_url").to_s.should be_a(String)
    end
  end

  describe CrystalDoc::Views::RepoList do
    it "renders to a string" do
      repo_list = [CrystalDoc::Repo.new("service", "username", "project_name")]
      CrystalDoc::Views::RepoList.new(repo_list).to_s.should be_a(String)
    end
  end

  describe "#format_span" do
    it "formats time spans" do
      views = CrystalDoc::Views

      views.format_span(
        Time::Span.new(seconds: 1)
      ).should eq("00:00:01")
      views.format_span(
        Time::Span.new(minutes: 2, seconds: 1)
      ).should eq("00:02:01")
      views.format_span(
        Time::Span.new(hours: 3, minutes: 2, seconds: 1)
      ).should eq("03:02:01")
      views.format_span(
        Time::Span.new(days: 4, hours: 3, minutes: 2, seconds: 1)
      ).should eq("4d 03:02:01")
    end
  end
end
