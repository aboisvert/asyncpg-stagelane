# Integration-test PostgreSQL for asyncpg-stagelane.
#
# Build:
#   docker build -t asyncpg-postgres -f docker/postgres/Dockerfile docker/postgres
#
# Run (or use `just postgres-start` from repo root):
#   docker run --rm -d --name asyncpg-postgres -p 5432:5432 asyncpg-postgres
#
# Tests need a password; set ASYNCPG_DB or use just recipes that export it:
#   host=localhost port=5432 dbname=asyncpg user=postgres password=postgres

FROM postgres:latest

ENV POSTGRES_USER=postgres
ENV POSTGRES_PASSWORD=postgres
ENV POSTGRES_DB=asyncpg

EXPOSE 5432

HEALTHCHECK --interval=5s --timeout=5s --start-period=10s --retries=5 \
  CMD pg_isready -U postgres -d asyncpg || exit 1
