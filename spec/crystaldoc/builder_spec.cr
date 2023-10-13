require "../spec_helper"

describe CrystalDoc::Builder do
  context "returns true" do
    it "if doc generation succeeds" do
      builder = CrystalDoc::Builder.new

      repo = CrystalDoc::Repo.new("github", "crystal-lang", "shards", "https://github.com/crystal-lang/shards")

      builder.build_git(repo, "master").should eq(true)

      repo = CrystalDoc::Repo.new("github", "Ragmaanir", "id3", "https://github.com/Ragmaanir/id3")

      builder.build_git(repo, "v0.1.1").should eq(true)
    end
  end

  context "returns false" do
    it "if repo url doesn't exist" do
      builder = CrystalDoc::Builder.new

      repo = CrystalDoc::Repo.new("this", "repo", "doesnt", "https://example.com/exist")

      builder.build_git(repo, "master").should eq(false)
    end

    it "if doc generation failed" do
      builder = CrystalDoc::Builder.new

      repo = CrystalDoc::Repo.new("github", "Ragmaanir", "id3", "https://github.com/Ragmaanir/id3")

      builder.build_git(repo, "0.1.0").should eq(false)
    end
  end

  it "builds fossil docs" do
    ENV["USER"] = "cicd"

    builder = CrystalDoc::Builder.new

    repo = CrystalDoc::Repo.new("chiselapp", "MistressRemilia", "libremiliacr", "https://chiselapp.com/user/MistressRemilia/repository/libremiliacr/index")

    builder.build_fossil(repo, "v0.11.2").should eq(true)
  end
end
