require "lexbor"

module CrystalDoc
  class Html
    # Allows applying a single post processing block to all html files in a directory.
    # Finds all html files in the specified path, opens and parses them with lexbor,
    # then yields the lexbor representation of the file and its path to the block;
    # when the block finishes, the changes are written back to the html file.
    def self.post_process(path : String, &)
      Dir.glob("#{path}/**/*.html").each do |file_path|
        File.open(file_path, mode: "r+") do |file|
          html = Lexbor::Parser.new(file)
          yield html, file_path
          modified = html.to_html
          file.rewind
          file.truncate
          file.print modified
        end
      end
    end
  end
end
