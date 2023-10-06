require "../spec_helper"

describe CrystalDoc::Builder do
  it "builds docs" do
    builder = CrystalDoc::Builder.new

    repo = CrystalDoc::Repo.new("github", "crystal-lang", "shards", "https://github.com/crystal-lang/shards")

    builder.build_git(repo, "master").should eq(true)
  end
end
