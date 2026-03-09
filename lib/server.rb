# frozen_string_literal: true

require "mcp"
require "logger"
require "fileutils"
require_relative "embedder"
require_relative "vector_store"
require_relative "indexer"
require_relative "link_checker"

module MarkdownMcp
  # The MCP server that exposes vault management and search tools.
  # Runs over stdio transport — Claude Desktop launches it as a subprocess.
  # Supports multiple independent vaults identified by name.
  class Server
    def initialize(db_url: nil, ollama_model: nil, ollama_url: nil)
      @logger = Logger.new($stderr, progname: "MarkdownMcp")

      @embedder = Embedder.new(
        model: ollama_model || ENV.fetch("OLLAMA_MODEL", Embedder::DEFAULT_MODEL),
        base_url: ollama_url || ENV.fetch("OLLAMA_URL", Embedder::DEFAULT_BASE_URL)
      )

      @store = VectorStore.new(
        db_url: db_url || ENV.fetch("DATABASE_URL", VectorStore::DEFAULT_DB_URL)
      )

      @indexer = Indexer.new(embedder: @embedder, store: @store)
    end

    def run
      # Ensure DB schema exists
      @store.setup!

      server = MCP::Server.new(
        name: "markdown_rag",
        version: "0.2.0",
        instructions: <<~INST
          You are working with one or more Obsidian vaults via semantic search and file tools.
          Each vault is a named, independent collection of markdown notes with its own search index.

          ## Vault selection
          - Always confirm which vault the user wants to work with before performing any operation.
          - Use vault_list_vaults to see what vaults exist.
          - Vault names are short identifiers like "drakkenheim", "flowdice", or "personal".
          - To create a new vault, call vault_index with a new name and the directory path — it registers automatically.

          ## Pre-write workflow (follow every time before vault_write)
          1. vault_list — browse the vault root and relevant subdirectories to check whether a file with a similar name already exists. If it does, use vault_read + vault_write (overwrite: true) to update it rather than creating a duplicate.
          2. vault_missing_links — check if the note you're about to create is already referenced elsewhere. If the target name does NOT appear as a missing link, a file by that name likely already exists somewhere in the vault — use vault_list to locate it.
          3. vault_search — find semantically related notes to understand context and avoid duplicating content that belongs in an existing file.
          4. Propose the intended file_path, filename, and a content outline to the user and wait for confirmation before calling vault_write.

          ## Post-write workflow
          5. After vault_write succeeds, call vault_add_backlinks to wire related notes back to the new page.
          6. Report what was written and what backlinks were added.

          ## Conventions
          If a file named `_conventions.md` exists at the vault root, read it with vault_read before starting any write workflow — it documents naming rules, folder structure, and content patterns for this specific vault.
        INST
      )

      register_tools(server)

      @logger.info("Starting MCP server over stdio...")
      transport = MCP::Server::Transports::StdioTransport.new(server)
      transport.open
    end

    private

    def register_tools(server)
      embedder = @embedder
      store = @store
      indexer = @indexer
      logger = @logger

      # --- Tool: vault_list_vaults ---
      server.define_tool(
        name: "vault_list_vaults",
        description: <<~DESC.strip,
          List all registered vaults and their root directories.
          Use this to discover which vaults are available before searching or writing.
          Returns each vault's name, root path, and when it was first indexed.
        DESC
        input_schema: { type: "object", properties: {} },
        annotations: {
          read_only_hint: true,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false
        }
      ) do |**_|
        begin
          vaults = store.list_vaults

          if vaults.empty?
            MCP::Tool::Response.new([{
              type: "text",
              text: "No vaults registered yet. Use vault_index to index a directory and create a vault."
            }])
          else
            lines = ["Registered vaults (#{vaults.size}):"]
            vaults.each do |v|
              lines << "  #{v[:name]}"
              lines << "    root: #{v[:root_path]}"
              lines << "    created: #{v[:created_at]}"
            end
            MCP::Tool::Response.new([{ type: "text", text: lines.join("\n") }])
          end
        rescue => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end

      # --- Tool: vault_list ---
      server.define_tool(
        name: "vault_list",
        description: <<~DESC.strip,
          List files and folders in a vault directory. Use this before writing to discover
          existing files that might match what you're about to create, and to understand
          the vault's folder structure and naming conventions.
          Returns a tree of .md files and subdirectories. Set recursive to true to see
          the full subtree.
        DESC
        input_schema: {
          type: "object",
          properties: {
            directory: {
              type: "string",
              description: "Absolute path to the directory to list (e.g. /vault or /vault/People)"
            },
            recursive: {
              type: "boolean",
              description: "Include subdirectories recursively. Default: false"
            }
          },
          required: ["directory"]
        },
        annotations: {
          read_only_hint: true,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false
        }
      ) do |directory:, recursive: false|
        begin
          directory = File.expand_path(directory)
          unless Dir.exist?(directory)
            next MCP::Tool::Response.new([{ type: "text", text: "Error: Directory not found: #{directory}" }])
          end

          lines = []

          build_tree = lambda do |dir, prefix|
            entries = Dir.entries(dir).reject { |e| e.start_with?(".") }.sort_by { |e|
              [File.directory?(File.join(dir, e)) ? 0 : 1, e.downcase]
            }

            entries.each_with_index do |entry, i|
              abs = File.join(dir, entry)
              last = i == entries.size - 1
              connector = last ? "└── " : "├── "
              child_prefix = last ? "    " : "│   "

              if File.directory?(abs)
                lines << "#{prefix}#{connector}#{entry}/"
                build_tree.call(abs, prefix + child_prefix) if recursive
              elsif entry.end_with?(".md")
                lines << "#{prefix}#{connector}#{entry}"
              end
            end
          end

          lines << directory
          build_tree.call(directory, "")

          MCP::Tool::Response.new([{ type: "text", text: lines.join("\n") }])
        rescue => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end

      # --- Tool: vault_index ---
      server.define_tool(
        name: "vault_index",
        description: <<~DESC.strip,
          Index markdown files from a directory into a named vault's search index.
          The vault name is a short identifier (e.g. "drakkenheim", "personal").
          Creating a vault for the first time: provide a new name and a directory path.
          Supports incremental updates (only re-indexes changed files) by default.
          Set force_reindex to true to rebuild the vault's index from scratch.
          Set recursive to true to include subdirectories.
        DESC
        input_schema: {
          type: "object",
          properties: {
            vault: {
              type: "string",
              description: "Short name for this vault (e.g. \"drakkenheim\", \"personal\")"
            },
            directory: {
              type: "string",
              description: "Absolute path to the folder containing .md files"
            },
            force_reindex: {
              type: "boolean",
              description: "If true, clears and rebuilds the full index for this vault. Default: false"
            },
            recursive: {
              type: "boolean",
              description: "If true, includes all subdirectories. Default: false"
            }
          },
          required: ["vault", "directory"]
        },
        annotations: {
          read_only_hint: false,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false
        }
      ) do |vault:, directory:, force_reindex: false, recursive: false|
        logger.info("Indexing vault '#{vault}': #{directory} (force=#{force_reindex}, recursive=#{recursive})")

        begin
          directory = File.expand_path(directory)
          store.register_vault(vault, directory)
          stats = indexer.index(directory: directory, vault_name: vault, force_reindex: force_reindex, recursive: recursive)

          summary = [
            "Indexing complete for vault '#{vault}' (#{directory})",
            "Files scanned: #{stats[:files_scanned]}",
            "Files indexed (changed): #{stats[:files_indexed]}",
            "Chunks added: #{stats[:chunks_added]}",
            "Chunks skipped (unchanged): #{stats[:chunks_skipped]}",
            "Files removed (deleted from disk): #{stats[:files_removed]}",
            "Total chunks in vault: #{store.count(vault_name: vault)}"
          ].join("\n")

          MCP::Tool::Response.new([{ type: "text", text: summary }])
        rescue => e
          logger.error("Index error: #{e.message}")
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end

      # --- Tool: vault_search ---
      server.define_tool(
        name: "vault_search",
        description: <<~DESC.strip,
          Semantic search over a named vault's indexed markdown documents.
          Returns the most relevant chunks based on meaning, not just keywords.
          Results include the source file path, heading, and content.
          Only searches within the specified vault — results are fully isolated.
        DESC
        input_schema: {
          type: "object",
          properties: {
            vault: {
              type: "string",
              description: "Name of the vault to search (e.g. \"drakkenheim\")"
            },
            query: {
              type: "string",
              description: "Natural language search query"
            },
            limit: {
              type: "integer",
              description: "Max number of results to return (default: 5, max: 20)"
            }
          },
          required: ["vault", "query"]
        },
        annotations: {
          read_only_hint: true,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false
        }
      ) do |vault:, query:, limit: 5|
        limit = [limit.to_i, 20].min
        logger.info("Search vault '#{vault}': '#{query}' (limit=#{limit})")

        begin
          query_embedding = embedder.embed(query)
          results = store.search(query_embedding, vault_name: vault, limit: limit)

          if results.empty?
            MCP::Tool::Response.new([{
              type: "text",
              text: "No results found in vault '#{vault}'. Has it been indexed? Use vault_index first."
            }])
          else
            formatted = results.map.with_index do |r, i|
              parts = ["--- Result #{i + 1} (distance: #{r[:distance].round(4)}) ---"]
              parts << "File: #{r[:file_path]}"
              parts << "Title: #{r[:doc_title]}" if r[:doc_title]
              parts << "Section: #{r[:heading]}" if r[:heading]
              parts << "Tags: #{r[:tags]}" if r[:tags] && !r[:tags].empty?
              parts << ""
              parts << r[:content]
              parts.join("\n")
            end

            MCP::Tool::Response.new([{ type: "text", text: formatted.join("\n\n") }])
          end
        rescue => e
          logger.error("Search error: #{e.message}")
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end

      # --- Tool: vault_read ---
      server.define_tool(
        name: "vault_read",
        description: "Read the full markdown content of a vault file. Use this before modifying a file or to check its existing links and structure.",
        input_schema: {
          type: "object",
          properties: {
            file_path: {
              type: "string",
              description: "Absolute path to the .md file to read"
            }
          },
          required: ["file_path"]
        },
        annotations: {
          read_only_hint: true,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false
        }
      ) do |file_path:|
        begin
          unless File.exist?(file_path)
            next MCP::Tool::Response.new([{ type: "text", text: "Error: File not found: #{file_path}" }])
          end
          content = File.read(file_path, encoding: "utf-8")
          MCP::Tool::Response.new([{ type: "text", text: content }])
        rescue => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end

      # --- Tool: vault_add_backlinks ---
      server.define_tool(
        name: "vault_add_backlinks",
        description: <<~DESC.strip,
          After writing a new note, call this to find semantically related existing notes
          in the same vault and add a [[wikilink]] back to the new note in each of them.
          Skips files that already contain the link. Appends to an existing "## Related"
          section if present, otherwise creates one at the end of the file.
          Returns a list of files that were updated.
        DESC
        input_schema: {
          type: "object",
          properties: {
            vault: {
              type: "string",
              description: "Name of the vault the file belongs to"
            },
            file_path: {
              type: "string",
              description: "Absolute path to the newly created .md file"
            },
            limit: {
              type: "integer",
              description: "Max number of related files to consider (default: 8)"
            }
          },
          required: ["vault", "file_path"]
        },
        annotations: {
          read_only_hint: false,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false
        }
      ) do |vault:, file_path:, limit: 8|
        begin
          unless File.exist?(file_path)
            next MCP::Tool::Response.new([{ type: "text", text: "Error: File not found: #{file_path}" }])
          end

          note_name = File.basename(file_path, ".md")
          content = File.read(file_path, encoding: "utf-8")

          # Embed the new note to find related content within the same vault
          query_embedding = embedder.embed(content.slice(0, 3000))
          results = store.search(query_embedding, vault_name: vault, limit: limit * 3)

          # Unique related files, excluding the new note itself
          related_files = results.map { |r| r[:file_path] }.uniq.reject { |f| f == file_path }

          link_pattern = /\[\[#{Regexp.escape(note_name)}(?:\|[^\]]*)?\]\]/i

          updated = []
          related_files.first(limit).each do |related_path|
            next unless File.exist?(related_path)

            related_content = File.read(related_path, encoding: "utf-8")
            next if related_content.match?(link_pattern)

            # Append to existing ## Related / ## See Also section, or create one
            if related_content.match?(/^## (?:Related|See [Aa]lso)\b/m)
              related_content = related_content.sub(
                /(^## (?:Related|See [Aa]lso)\b[^\n]*\n)(.*?)(\n^##|\z)/m
              ) { "#{$1}#{$2}- [[#{note_name}]]\n#{$3}" }
            else
              related_content = related_content.rstrip + "\n\n## Related\n- [[#{note_name}]]\n"
            end

            File.write(related_path, related_content)
            indexer.index_one(related_path, vault_name: vault)
            updated << File.basename(related_path, ".md")
          end

          if updated.empty?
            MCP::Tool::Response.new([{ type: "text", text: "No related files needed backlinks to [[#{note_name}]] in vault '#{vault}'." }])
          else
            MCP::Tool::Response.new([{
              type: "text",
              text: "Added [[#{note_name}]] to #{updated.size} file(s) in vault '#{vault}':\n" + updated.map { |n| "  - #{n}" }.join("\n")
            }])
          end
        rescue => e
          logger.error("Add backlinks error: #{e.message}")
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end

      # --- Tool: vault_write ---
      server.define_tool(
        name: "vault_write",
        description: <<~DESC.strip,
          Write or update a markdown file in a vault, then re-index it automatically.
          Use this to create new notes or update existing ones.
          The file_path must be an absolute path inside the vault's directory.
          Set overwrite to true to replace an existing file (default: false).
        DESC
        input_schema: {
          type: "object",
          properties: {
            vault: {
              type: "string",
              description: "Name of the vault to write into"
            },
            file_path: {
              type: "string",
              description: "Absolute path to the .md file to write (must be inside the vault)"
            },
            content: {
              type: "string",
              description: "Full markdown content to write to the file"
            },
            overwrite: {
              type: "boolean",
              description: "If true, overwrite an existing file. Default: false"
            }
          },
          required: ["vault", "file_path", "content"]
        },
        annotations: {
          read_only_hint: false,
          destructive_hint: true,
          idempotent_hint: false,
          open_world_hint: false
        }
      ) do |vault:, file_path:, content:, overwrite: false|
        begin
          if File.exist?(file_path) && !overwrite
            next MCP::Tool::Response.new([{
              type: "text",
              text: "Error: #{file_path} already exists. Set overwrite: true to replace it."
            }])
          end

          FileUtils.mkdir_p(File.dirname(file_path))
          File.write(file_path, content)
          logger.info("Wrote #{file_path} (#{content.bytesize} bytes) into vault '#{vault}'")

          stats = indexer.index_one(file_path, vault_name: vault)

          MCP::Tool::Response.new([{
            type: "text",
            text: "Written and indexed into vault '#{vault}': #{file_path}\nChunks added: #{stats[:chunks_added]}"
          }])
        rescue => e
          logger.error("Write error: #{e.message}")
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end

      # --- Tool: vault_missing_links ---
      server.define_tool(
        name: "vault_missing_links",
        description: <<~DESC.strip,
          Scan the vault for Obsidian [[wikilinks]] that point to notes that don't exist yet.
          Useful for finding broken references or notes that still need to be created.
          Returns each missing link target, how many files reference it, and which files.
          Set recursive to false to only check the top-level directory.
        DESC
        input_schema: {
          type: "object",
          properties: {
            directory: {
              type: "string",
              description: "Root directory of the vault to scan"
            },
            recursive: {
              type: "boolean",
              description: "Include subdirectories. Default: true"
            }
          },
          required: ["directory"]
        },
        annotations: {
          read_only_hint: true,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false
        }
      ) do |directory:, recursive: true|
        begin
          result = LinkChecker.new(directory: directory, recursive: recursive).check

          if result.missing.empty?
            MCP::Tool::Response.new([{
              type: "text",
              text: "No missing links found! Scanned #{result.files_scanned} files, #{result.total_links} total links."
            }])
          else
            lines = [
              "Missing links: #{result.missing.size} unique targets",
              "Files scanned: #{result.files_scanned}",
              "Total links checked: #{result.total_links}",
              ""
            ]

            result.missing.each do |m|
              lines << "[[#{m.target}]] — #{m.referencing_files.size} reference(s):"
              m.referencing_files.each { |f| lines << "  - #{f}" }
              lines << ""
            end

            MCP::Tool::Response.new([{ type: "text", text: lines.join("\n") }])
          end
        rescue => e
          logger.error("Link check error: #{e.message}")
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end

      # --- Tool: vault_status ---
      server.define_tool(
        name: "vault_status",
        description: "Check the current state of a vault's index: total chunks and indexed files.",
        input_schema: {
          type: "object",
          properties: {
            vault: {
              type: "string",
              description: "Name of the vault to check"
            }
          },
          required: ["vault"]
        },
        annotations: {
          read_only_hint: true,
          destructive_hint: false,
          idempotent_hint: true,
          open_world_hint: false
        }
      ) do |vault:|
        begin
          files = store.indexed_files(vault_name: vault)
          count = store.count(vault_name: vault)

          summary = [
            "Index status for vault '#{vault}':",
            "Total chunks: #{count}",
            "Indexed files: #{files.length}",
            "",
            "Files:",
            *files.map { |f| "  - #{f}" }
          ].join("\n")

          MCP::Tool::Response.new([{ type: "text", text: summary }])
        rescue => e
          MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}" }])
        end
      end
    end
  end
end
