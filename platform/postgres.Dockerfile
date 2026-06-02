FROM postgres:17-bookworm AS base

# Install older postgresql-16 binaries (required for pg_upgrade) and postgresql-17-pgvector
RUN apt-get update && apt-get install -y \
    postgresql-16 \
    postgresql-17-pgvector \
    && rm -rf /var/lib/apt/lists/*

# Add initialization script to enable extensions on all new databases
RUN echo "CREATE EXTENSION IF NOT EXISTS vector;" > /docker-entrypoint-initdb.d/01_pgvector.sql
RUN echo "CREATE EXTENSION IF NOT EXISTS cube;" >> /docker-entrypoint-initdb.d/01_pgvector.sql
RUN echo "CREATE EXTENSION IF NOT EXISTS earthdistance;" >> /docker-entrypoint-initdb.d/01_pgvector.sql

FROM base AS final

# Add our hands-free automated version upgrade entrypoint wrapper
COPY scripts/db_upgrade_entrypoint.sh /usr/local/bin/db_upgrade_entrypoint.sh
RUN chmod +x /usr/local/bin/db_upgrade_entrypoint.sh

ENTRYPOINT ["/usr/local/bin/db_upgrade_entrypoint.sh"]
CMD ["postgres"]
