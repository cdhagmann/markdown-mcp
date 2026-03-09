# frozen_string_literal: true

module MarkdownMcp
  # Scans a vault directory for Obsidian [[wikilinks]] that point to notes
  # that don't exist on disk.
  #
  # Obsidian link resolution rules (simplified):
  #   - [[Note Name]]          -> looks for Note Name.md anywhere in vault
  #   - [[Folder/Note Name]]   -> looks for that relative path from vault root
  #   - [[Note Name#Heading]]  -> note part only (heading ignored for existence check)
  #   - [[Note Name|Alias]]    -> note part only (alias ignored)
  class LinkChecker
    Result = Struct.new(:missing, :total_links, :files_scanned, keyword_init: true)

    MissingLink = Struct.new(:target, :referencing_files, keyword_init: true)

    # Regex to extract the note target from [[...]] links.
    # Captures everything up to |, #, or ]]
    WIKILINK_RE = /\[\[([^\]|#\n]+)(?:[|#][^\]]*)?\]\]/

    def initialize(directory:, recursive: true)
      @directory = File.expand_path(directory)
      @recursive = recursive
    end

    def check
      pattern = @recursive ? File.join(@directory, "**", "*.md") : File.join(@directory, "*.md")
      all_files = Dir.glob(pattern).sort

      # Build lookup structures for Obsidian-style resolution.
      # Obsidian matches by basename (case-insensitive) OR by vault-relative path.
      known_by_name = {}  # downcased basename (no ext) => true
      known_by_path = {}  # downcased vault-relative path (no ext) => true

      all_files.each do |abs_path|
        rel = abs_path.sub(@directory + "/", "")
        base = File.basename(rel, ".md")
        known_by_name[base.downcase] = true
        known_by_path[rel.sub(/\.md$/, "").downcase] = true
      end

      # Track: link_target => Set of relative file paths that reference it
      missing = Hash.new { |h, k| h[k] = Set.new }
      total_links = 0

      all_files.each do |abs_path|
        rel = abs_path.sub(@directory + "/", "")
        begin
          content = File.read(abs_path, encoding: "utf-8")
        rescue => e
          next
        end

        content.scan(WIKILINK_RE) do |match|
          raw_target = match[0].strip
          next if raw_target.empty?

          total_links += 1

          # Resolve: if it looks like a path (contains /), check by vault-relative path
          # otherwise check by basename
          if raw_target.include?("/")
            exists = known_by_path[raw_target.downcase]
          else
            exists = known_by_name[raw_target.downcase]
          end

          missing[raw_target] << rel unless exists
        end
      end

      Result.new(
        missing: missing.map { |target, refs|
          MissingLink.new(target: target, referencing_files: refs.to_a.sort)
        }.sort_by { |m| [-m.referencing_files.size, m.target.downcase] },
        total_links: total_links,
        files_scanned: all_files.size
      )
    end
  end
end
