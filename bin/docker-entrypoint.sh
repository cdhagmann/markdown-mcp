#!/bin/sh
set -e

echo "Running database setup..." >&2
ruby bin/setup_db >&2

echo "Starting MCP server..." >&2
exec ruby bin/server
