# Markdown RAG MCP Server (Ruby)

A local-first RAG (Retrieval-Augmented Generation) MCP server for Obsidian vaults
(or any directory of markdown files), written in Ruby.

Indexes your markdown notes into PostgreSQL with pgvector, generates embeddings
via Ollama, and serves semantic search results over the MCP protocol so Claude
can pull relevant context from your notes into any conversation.

## How It Works

1. **Indexing**: Point it at a directory of `.md` files. It splits them into
   chunks by heading, generates vector embeddings via Ollama, and stores
   everything in PostgreSQL with pgvector.

2. **Searching**: When Claude needs context, it calls `vault_search` with a
   natural language query. The server embeds the query, does a cosine similarity
   search against your chunks, and returns the most relevant results.

3. **Incremental updates**: On re-index, only changed files are re-processed.
   Deleted files are automatically cleaned up.

## Architecture

```
Obsidian Vault (.md files)
        │
        ▼
    Chunker (split by ## headings, preserve frontmatter + tags)
        │
        ▼
    Embedder (Ollama → nomic-embed-text, 768 dimensions)
        │
        ▼
    VectorStore (PostgreSQL + pgvector, HNSW index)
        │
        ▼
    MCP Server (stdio transport, official mcp-ruby-sdk)
        │
        ▼
    Claude Desktop
```

## Prerequisites

- Ruby 3.1+
- PostgreSQL with the `vector` extension
- Ollama running locally

## Setup

### 1. Install pgvector

If you're on macOS with Homebrew postgres:

```bash
# pgvector is often already available, just enable it:
psql -c "CREATE EXTENSION IF NOT EXISTS vector" your_database
```

Or install from source: https://github.com/pgvector/pgvector

### 2. Pull an embedding model

```bash
ollama pull nomic-embed-text
```

Small (~274MB), fast, 768 dimensions. Good default choice.

### 3. Install gems

```bash
bundle install
```

### 4. Create the database and schema

```bash
createdb obsidian_rag
ruby bin/setup_db
```

### 5. Test it

```bash
ruby bin/test_search /path/to/your/vault "what did I write about demand avoidance" 5
```

### 6. Configure Claude Desktop

Add to `~/.config/claude/claude_desktop_config.json` (or the macOS equivalent):

```json
{
  "mcpServers": {
    "obsidian_rag": {
      "command": "ruby",
      "args": ["/Users/christopherhagmann/Projects/Personal/markdown-mcp/bin/server"],
      "env": {
        "DATABASE_URL": "postgresql://localhost/obsidian_rag",
        "OLLAMA_MODEL": "nomic-embed-text",
        "OLLAMA_URL": "http://localhost:11434"
      }
    }
  }
}
```

## MCP Tools

### `vault_index`

Index markdown files from a directory.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| directory | string | yes | — | Absolute path to folder with .md files |
| force_reindex | boolean | no | false | Clear and rebuild entire index |
| recursive | boolean | no | false | Include subdirectories |

### `vault_search`

Semantic search over indexed documents.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| query | string | yes | — | Natural language search query |
| limit | integer | no | 5 | Max results (capped at 20) |

### `vault_status`

Check index health: total chunks and indexed files.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| DATABASE_URL | postgresql://localhost/obsidian_rag | PostgreSQL connection string |
| OLLAMA_MODEL | nomic-embed-text | Ollama embedding model name |
| OLLAMA_URL | http://localhost:11434 | Ollama API base URL |

## Project Structure

```
markdown-mcp/
├── bin/
│   ├── server          # MCP server entry point (stdio)
│   ├── setup_db        # One-time database setup
│   └── test_search     # CLI tool for testing
├── lib/
│   ├── chunker.rb      # Markdown → chunks (by heading)
│   ├── embedder.rb     # Ollama embedding client
│   ├── indexer.rb       # Orchestrates chunk + embed + store
│   ├── server.rb       # MCP server with tool definitions
│   └── vector_store.rb # pgvector CRUD + similarity search
├── Gemfile
└── README.md
```

## Design Decisions

**Why pgvector over ChromaDB/Milvus?** You're a Rails dev with Postgres already
running. One less service to manage. pgvector's HNSW index is plenty fast for
a personal vault (tens of thousands of chunks).

**Why Ollama over OpenAI embeddings?** Local, free, no API key needed. Your
notes never leave your machine. Swap to OpenAI by changing the Embedder class
if you want — the interface is the same.

**Why chunk by h2 headings?** Obsidian notes are structured by headings.
Chunking by `##` preserves semantic boundaries that the author intended.
Each chunk gets the document title prepended for context, so a search for
"demand avoidance bedtime" can match a chunk from a specific section without
losing which document it belongs to.

**Why the official MCP SDK?** It handles the JSON-RPC protocol, stdio
transport, and tool registration. Less hand-rolled protocol code to debug.
