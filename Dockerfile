FROM ruby:3.3-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY bin/ bin/
COPY lib/ lib/

RUN chmod +x bin/server bin/setup_db bin/test_search bin/docker-entrypoint.sh

ENV DATABASE_URL=postgresql://postgres:postgres@postgres:5432/obsidian_rag
ENV OLLAMA_URL=http://ollama:11434
ENV OLLAMA_MODEL=nomic-embed-text

ENTRYPOINT ["bin/docker-entrypoint.sh"]
