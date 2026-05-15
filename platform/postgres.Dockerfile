FROM postgres:16-bookworm

# Install pgvector directly into the image
RUN apt-get update && apt-get install -y \
    postgresql-16-pgvector \
    && rm -rf /var/lib/apt/lists/*

# Add initialization script to enable extension on all new databases
RUN echo "CREATE EXTENSION IF NOT EXISTS vector;" > /docker-entrypoint-initdb.d/01_pgvector.sql
RUN echo "CREATE EXTENSION IF NOT EXISTS cube;" >> /docker-entrypoint-initdb.d/01_pgvector.sql
RUN echo "CREATE EXTENSION IF NOT EXISTS earthdistance;" >> /docker-entrypoint-initdb.d/01_pgvector.sql
