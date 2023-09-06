require "../spec_helper"

describe CrystalDoc::Html do
  describe "#post_process" do
    it "parses html in a folder" do
      tempdir = "#{Dir.tempdir}/crystaldoc/html_spec"
      Dir.mkdir_p(tempdir)

      tempfile = File.tempfile(suffix: ".html", dir: tempdir)

      File.write(tempfile.path, <<-HTML)
      <div class="test-class"></div>
      HTML

      CrystalDoc::Html.post_process(tempdir) do |html, path|
        path.should eq(tempfile.path)

        test_class = html.css(".test-class").first
        test_class.inner_html = <<-HTML
        <p>Inner content</p>
        HTML
      end

      File.read(tempfile.path).gsub(/\n/, "").should eq(%(<html><head></head><body><div class="test-class"><p>Inner content</p></div></body></html>))
    ensure
      tempfile.try &.delete
    end
  end
end
