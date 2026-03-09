# frozen_string_literal: true

require "digest"

module MarkdownMcp
  # Splits markdown files into chunks based on heading structure.
  # Respects Obsidian conventions: YAML frontmatter, wikilinks, tags.
  #
  # Chunking strategy:
  #   - Split on ## headings (h2) as primary boundaries
  #   - Keep h1 (#) as document-level context prepended to each chunk
  #   - Preserve frontmatter as metadata, not chunk content
  #   - Each chunk carries its source file path and heading breadcrumb
  class Chunker
    Chunk = Struct.new(:content, :metadata, keyword_init: true) do
      def content_hash
        Digest::SHA256.hexdigest(content)
      end
    end

    # Parses a markdown file and returns an array of Chunks.
    # Each chunk has :content (the text) and :metadata (hash with
    # file_path, heading, tags, frontmatter fields, etc.)
    def chunk_file(file_path)
      raw = File.read(file_path, encoding: "utf-8")
      frontmatter, body = extract_frontmatter(raw)

      # Extract Obsidian tags from body (e.g., #tag-name)
      tags = extract_tags(body)
      tags += Array(frontmatter["tags"]) if frontmatter["tags"]
      tags.uniq!

      # Get the document title from frontmatter or first h1
      doc_title = frontmatter["title"] || extract_first_heading(body) || File.basename(file_path, ".md")

      sections = split_by_headings(body)

      # If there's only one section (no headings), return the whole thing
      if sections.length <= 1
        content = body.strip
        return [] if content.empty?

        return [
          Chunk.new(
            content: content,
            metadata: {
              file_path: file_path,
              doc_title: doc_title,
              heading: nil,
              tags: tags,
              frontmatter: frontmatter
            }
          )
        ]
      end

      sections.filter_map do |heading, text|
        content = text.strip
        next if content.empty?

        # Prepend document title for context if this is a subsection
        contextualized = if heading
                           "# #{doc_title}\n## #{heading}\n\n#{content}"
                         else
                           "# #{doc_title}\n\n#{content}"
                         end

        Chunk.new(
          content: contextualized,
          metadata: {
            file_path: file_path,
            doc_title: doc_title,
            heading: heading,
            tags: tags,
            frontmatter: frontmatter
          }
        )
      end
    end

    private

    # Extracts YAML frontmatter from markdown. Returns [hash, remaining_body].
    def extract_frontmatter(raw)
      if raw.start_with?("---")
        parts = raw.split("---", 3)
        if parts.length >= 3
          require "yaml"
          fm = YAML.safe_load(parts[1]) || {}
          return [fm, parts[2..].join("---")]
        end
      end
      [{}, raw]
    end

    # Finds #tags in body text (Obsidian style), ignoring headings
    def extract_tags(body)
      # Match #word but not ## headings (must be preceded by space or start of line)
      body.scan(/(?:^|\s)#([a-zA-Z][\w\-\/]*)/).flatten.uniq
    end

    def extract_first_heading(body)
      match = body.match(/^#\s+(.+)$/)
      match&.[](1)&.strip
    end

    # Splits markdown body into sections by h2 (##) headings.
    # Returns array of [heading_text_or_nil, section_body] pairs.
    def split_by_headings(body)
      sections = []
      current_heading = nil
      current_lines = []

      body.each_line do |line|
        if line.match?(/^##\s+/)
          # Save previous section
          sections << [current_heading, current_lines.join] unless current_lines.empty?

          current_heading = line.sub(/^##\s+/, "").strip
          current_lines = []
        else
          current_lines << line
        end
      end

      # Don't forget the last section
      sections << [current_heading, current_lines.join] unless current_lines.empty?

      sections
    end
  end
end
