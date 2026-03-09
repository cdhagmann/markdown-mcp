# frozen_string_literal: true

require "logger"
require_relative "chunker"
require_relative "embedder"
require_relative "vector_store"

module MarkdownMcp
  # Orchestrates the indexing pipeline: finds markdown files, chunks them,
  # generates embeddings, and stores everything in pgvector.
  #
  # All operations are scoped to a vault_name for full isolation between vaults.
  #
  # Supports two modes:
  #   - Full reindex: clears everything for the vault and rebuilds
  #   - Incremental: only re-indexes files whose content has changed
  class Indexer
    attr_reader :chunker, :embedder, :store

    def initialize(embedder:, store:)
      @chunker = Chunker.new
      @embedder = embedder
      @store = store
      @logger = Logger.new($stderr, progname: "Indexer")
    end

    # Index a single file by path into the given vault. Re-indexes if changed.
    # Returns a stats hash: { chunks_added:, chunks_skipped: }
    def index_one(file_path, vault_name:)
      file_path = File.expand_path(file_path)
      raise "File not found: #{file_path}" unless File.exist?(file_path)

      result = index_file(file_path, vault_name: vault_name)
      { chunks_added: result[:added], chunks_skipped: result[:skipped] }
    end

    # Index all .md files in the given directory into the given vault.
    # Returns a summary hash with counts.
    def index(directory:, vault_name:, force_reindex: false, recursive: true)
      directory = File.expand_path(directory)

      unless Dir.exist?(directory)
        raise "Directory not found: #{directory}"
      end

      pattern = recursive ? File.join(directory, "**", "*.md") : File.join(directory, "*.md")
      files = Dir.glob(pattern)

      @logger.info("Found #{files.length} markdown files in #{directory} (vault=#{vault_name})")

      if force_reindex
        @logger.info("Force reindex: clearing all chunks for vault '#{vault_name}'")
        store.clear!(vault_name: vault_name)
      end

      stats = { files_scanned: files.length, files_indexed: 0, chunks_added: 0, chunks_skipped: 0 }

      files.each do |file_path|
        result = index_file(file_path, vault_name: vault_name, force: force_reindex)
        stats[:files_indexed] += 1 if result[:changed]
        stats[:chunks_added] += result[:added]
        stats[:chunks_skipped] += result[:skipped]
      end

      # Clean up chunks for files that no longer exist
      removed = cleanup_deleted_files(directory, files, vault_name: vault_name)
      stats[:files_removed] = removed

      @logger.info("Indexing complete for vault '#{vault_name}': #{stats.inspect}")
      stats
    end

    private

    # Index a single file into a vault. Compares content hashes to skip unchanged chunks.
    def index_file(file_path, vault_name:, force: false)
      chunks = chunker.chunk_file(file_path)
      result = { changed: false, added: 0, skipped: 0 }

      if force
        # Already cleared, just insert everything
        insert_chunks(chunks, vault_name: vault_name)
        result[:changed] = true
        result[:added] = chunks.length
        return result
      end

      # Incremental: compare hashes
      existing_hashes = store.existing_hashes_for(file_path, vault_name: vault_name)
      new_hashes = chunks.map(&:content_hash)

      # If hashes match exactly, skip this file entirely
      if existing_hashes.sort == new_hashes.sort
        result[:skipped] = chunks.length
        return result
      end

      # Something changed — re-index this file
      @logger.info("Re-indexing changed file: #{file_path} (vault=#{vault_name})")
      store.delete_file(file_path, vault_name: vault_name)
      insert_chunks(chunks, vault_name: vault_name)
      result[:changed] = true
      result[:added] = chunks.length
      result
    end

    # Batch-embed and insert chunks into a vault.
    def insert_chunks(chunks, vault_name:)
      return if chunks.empty?

      texts = chunks.map(&:content)
      embeddings = embedder.embed_batch(texts)

      chunks.zip(embeddings).each do |chunk, embedding|
        store.insert(chunk, embedding, vault_name: vault_name)
      end
    end

    # Remove chunks for files that have been deleted from disk within a vault.
    def cleanup_deleted_files(directory, current_files, vault_name:)
      current_set = current_files.to_set
      indexed = store.indexed_files(vault_name: vault_name)

      removed = 0
      indexed.each do |file_path|
        next unless file_path.start_with?(directory)
        next if current_set.include?(file_path)

        @logger.info("Removing deleted file from index: #{file_path} (vault=#{vault_name})")
        store.delete_file(file_path, vault_name: vault_name)
        removed += 1
      end

      removed
    end
  end
end
