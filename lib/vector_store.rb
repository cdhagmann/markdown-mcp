# frozen_string_literal: true

require "pg"
require "pgvector"
require "json"
require "logger"

module MarkdownMcp
  # Manages the pgvector-backed store for document chunks and their embeddings.
  # Schema is created automatically on first use.
  # All chunk operations are scoped to a vault_name for full isolation.
  class VectorStore
    DEFAULT_DB_URL = "postgresql://localhost/obsidian_rag"

    def initialize(db_url: DEFAULT_DB_URL, dimensions: 768)
      @db_url = db_url
      @dimensions = dimensions
      @logger = Logger.new($stderr, progname: "VectorStore")
      @conn = nil
    end

    def connection
      @conn ||= begin
        conn = PG.connect(@db_url)
        conn.exec("CREATE EXTENSION IF NOT EXISTS vector")
        registry = PG::BasicTypeRegistry.new.define_default_types
        Pgvector::PG.register_vector(registry)
        conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn, registry: registry)
        conn
      end
    end

    # Creates all tables and indexes if they don't exist.
    # Safe to run on existing installations — migrates vault_name column if missing.
    def setup!
      connection.exec(<<~SQL)
        CREATE TABLE IF NOT EXISTS vaults (
          name TEXT PRIMARY KEY,
          root_path TEXT NOT NULL,
          created_at TIMESTAMP DEFAULT NOW()
        );

        CREATE TABLE IF NOT EXISTS chunks (
          id BIGSERIAL PRIMARY KEY,
          vault_name TEXT NOT NULL DEFAULT 'default',
          file_path TEXT NOT NULL,
          doc_title TEXT,
          heading TEXT,
          content TEXT NOT NULL,
          content_hash TEXT NOT NULL,
          tags TEXT[] DEFAULT '{}',
          metadata JSONB DEFAULT '{}',
          embedding vector(#{@dimensions}),
          indexed_at TIMESTAMP DEFAULT NOW()
        );
      SQL

      # Migration: add vault_name to existing installations before creating index on it
      connection.exec(<<~SQL)
        ALTER TABLE chunks ADD COLUMN IF NOT EXISTS vault_name TEXT NOT NULL DEFAULT 'default';
      SQL

      connection.exec(<<~SQL)
        CREATE INDEX IF NOT EXISTS idx_chunks_file_path ON chunks(file_path);
        CREATE INDEX IF NOT EXISTS idx_chunks_content_hash ON chunks(content_hash);
        CREATE INDEX IF NOT EXISTS idx_chunks_vault_name ON chunks(vault_name);
        CREATE INDEX IF NOT EXISTS idx_chunks_embedding
        ON chunks
        USING hnsw (embedding vector_cosine_ops);
      SQL

      @logger.info("Database schema ready (dimensions=#{@dimensions})")
    end

    # --- Vault registry ---

    # Register or update a vault's root path.
    def register_vault(name, root_path)
      connection.exec_params(
        "INSERT INTO vaults (name, root_path) VALUES ($1, $2) ON CONFLICT (name) DO UPDATE SET root_path = $2",
        [name, root_path]
      )
    end

    # Returns all registered vaults as [{name:, root_path:, created_at:}].
    def list_vaults
      results = connection.exec("SELECT name, root_path, created_at FROM vaults ORDER BY name")
      results.map { |r| { name: r["name"], root_path: r["root_path"], created_at: r["created_at"] } }
    end

    # --- Chunk operations (all scoped to vault_name) ---

    # Removes all chunks for a given file path within a vault.
    def delete_file(file_path, vault_name:)
      result = connection.exec_params(
        "DELETE FROM chunks WHERE file_path = $1 AND vault_name = $2",
        [file_path, vault_name]
      )
      result.cmd_tuples
    end

    # Removes all chunks for a vault (does not delete the vault registry entry).
    def clear!(vault_name:)
      connection.exec_params("DELETE FROM chunks WHERE vault_name = $1", [vault_name])
    end

    # Inserts a chunk with its embedding into the specified vault.
    def insert(chunk, embedding, vault_name:)
      connection.exec_params(
        <<~SQL,
          INSERT INTO chunks (vault_name, file_path, doc_title, heading, content, content_hash, tags, metadata, embedding)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        SQL
        [
          vault_name,
          chunk.metadata[:file_path],
          chunk.metadata[:doc_title],
          chunk.metadata[:heading],
          chunk.content,
          chunk.content_hash,
          "{#{chunk.metadata[:tags].join(',')}}",
          JSON.generate(chunk.metadata[:frontmatter] || {}),
          Pgvector.encode(embedding)
        ]
      )
    end

    # Semantic search scoped to a vault.
    def search(query_embedding, vault_name:, limit: 5)
      results = connection.exec_params(
        <<~SQL,
          SELECT
            content, file_path, doc_title, heading, tags, metadata,
            embedding <=> $1 AS distance
          FROM chunks
          WHERE vault_name = $2
          ORDER BY embedding <=> $1
          LIMIT $3
        SQL
        [Pgvector.encode(query_embedding), vault_name, limit]
      )

      results.map do |row|
        {
          content: row["content"],
          file_path: row["file_path"],
          doc_title: row["doc_title"],
          heading: row["heading"],
          distance: row["distance"].to_f,
          tags: row["tags"],
          metadata: row["metadata"] || {}
        }
      end
    end

    # Returns all content hashes currently in the store for a file in a vault.
    def existing_hashes_for(file_path, vault_name:)
      results = connection.exec_params(
        "SELECT content_hash FROM chunks WHERE file_path = $1 AND vault_name = $2",
        [file_path, vault_name]
      )
      results.map { |r| r["content_hash"] }
    end

    # Returns all distinct file paths in a vault.
    def indexed_files(vault_name:)
      results = connection.exec_params(
        "SELECT DISTINCT file_path FROM chunks WHERE vault_name = $1 ORDER BY file_path",
        [vault_name]
      )
      results.map { |r| r["file_path"] }
    end

    # Returns total chunk count for a vault.
    def count(vault_name:)
      result = connection.exec_params(
        "SELECT COUNT(*) AS cnt FROM chunks WHERE vault_name = $1",
        [vault_name]
      )
      result.first["cnt"].to_i
    end
  end
end
