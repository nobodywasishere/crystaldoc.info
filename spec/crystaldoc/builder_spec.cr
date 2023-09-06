require "../spec_helper"

describe CrystalDoc::Builder do
  it "builds docs" do
    builder = CrystalDoc::Builder.new(
      "https://github.com/crystal-lang/shards",
      "github", "crystal-lang", "shards",
      "master"
    )

    builder.build.should eq(true)
  end
end
