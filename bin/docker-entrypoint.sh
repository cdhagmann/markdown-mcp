#!/bin/sh
set -e

# Wait for Postgres to be ready before attempting setup.
# This handles cold Docker starts where postgres takes time to initialize.
echo "Waiting for Postgres..." >&2
i=0
until pg_isready -h postgres -U postgres -q 2>/dev/null; do
  i=$((i + 1))
  if [ $i -ge 30 ]; then
    echo "Postgres did not become ready in time." >&2
    exit 1
  fi
  sleep 2
done
echo "Postgres ready." >&2

echo "Running database setup..." >&2
ruby bin/setup_db >&2

echo "Starting MCP server..." >&2
exec ruby bin/server
