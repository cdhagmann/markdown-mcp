# frozen_string_literal: true

require "httparty"
require "logger"

module MarkdownMcp
  # Talks to Ollama's /api/embed endpoint to generate vector embeddings.
  # Default model is nomic-embed-text (768 dimensions, good balance of
  # quality and speed). Swap it for any Ollama-supported embedding model.
  class Embedder
    DEFAULT_MODEL = "nomic-embed-text"
    DEFAULT_BASE_URL = "http://localhost:11435"

    attr_reader :model, :base_url, :dimensions

    def initialize(model: ENV.fetch("OLLAMA_MODEL", DEFAULT_MODEL),
                   base_url: ENV.fetch("OLLAMA_URL", DEFAULT_BASE_URL))
      @model = model
      @base_url = base_url
      @dimensions = nil # discovered on first embed call
      @logger = Logger.new($stderr, progname: "Embedder")
    end

    # Returns a single embedding vector (Array of floats) for the given text.
    def embed(text)
      result = embed_batch([text])
      result.first
    end

    # Returns an array of embedding vectors for multiple texts.
    # Ollama supports batch embedding natively which is much faster
    # than calling one at a time.
    def embed_batch(texts)
      response = HTTParty.post(
        "#{base_url}/api/embed",
        body: { model: model, input: texts }.to_json,
        headers: { "Content-Type" => "application/json" },
        timeout: 120
      )

      unless response.success?
        raise "Ollama embed failed (#{response.code}): #{response.body}"
      end

      embeddings = response.parsed_response["embeddings"]

      # Discover dimensions from first response
      @dimensions ||= embeddings.first&.length

      embeddings
    end
  end
end
