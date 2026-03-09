@echo off
cd /d "%~dp0\.."
docker compose up -d --wait 2>nul
docker run -i --rm ^
  --network markdown-mcp_default ^
  -e DATABASE_URL=postgresql://postgres:postgres@postgres:5432/obsidian_rag ^
  -e OLLAMA_URL=http://ollama:11434 ^
  -e OLLAMA_MODEL=nomic-embed-text ^
  -v "%OBSIDIAN_VAULT%:/vault" ^
  markdown-mcp-server
