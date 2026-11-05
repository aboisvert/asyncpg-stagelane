# Local PostgreSQL for integration tests (see docker/postgres/Dockerfile).
# Recipes export ASYNCPG_DB for tests; or set the same connection string manually.

container_name := "asyncpg-postgres"
image_name := "asyncpg-postgres"
postgres_port := "5432"
postgres_user := "postgres"
postgres_password := "postgres"
postgres_db := "asyncpg"
dockerfile := "docker/postgres/Dockerfile"

export ASYNCPG_DB := "host=localhost port=" + postgres_port + " dbname=" + postgres_db + " user=" + postgres_user + " password=" + postgres_password

default:
    @just --list

# Build and run the test Postgres container; wait until it accepts connections.
postgres-start: _postgres-ready

postgres-stop:
    #!/usr/bin/env bash
    set -euo pipefail
    docker stop "{{{{container_name}}" 2>/dev/null || true
    docker rm "{{{{container_name}}" 2>/dev/null || true

# Drop and recreate the asyncpg database (container keeps running).
db-wipe: _postgres-ready
    @just _psql-exec "DROP DATABASE IF EXISTS {{postgres_db}} WITH (FORCE);"
    @just _psql-exec "CREATE DATABASE {{postgres_db}} OWNER {{postgres_user}};"

# Remove the container and start a fresh Postgres instance.
db-refresh:
    @just postgres-stop
    @just postgres-start

# Compile all integration tests (Appveyor build_script; Unix paths).
test-build:
    #!/usr/bin/env bash
    set -euo pipefail
    tests=(test_types test_pool test_rows test_notifies test_utils)
    for name in "${tests[@]}"; do
      nimble c --path:"." "tests/${name}.nim"
    done
    cd tests
    for name in "${tests[@]}"; do
      mv "${name}" "${name}_plain"
    done
    cd ..
    nimble install .
    cd tests
    for name in "${tests[@]}"; do
      nim c "${name}.nim"
    done
    cd ..

# Run all integration test binaries (Appveyor test_script; Unix paths).
test-run:
    #!/usr/bin/env bash
    set -euo pipefail
    tests=(test_types test_pool test_rows test_notifies test_utils)
    for name in "${tests[@]}"; do
      "tests/${name}_plain"
      "tests/${name}"
    done

# Start Postgres, build, and run the full integration test suite.
test: _postgres-ready test-build test-run

[private]
_postgres-ready:
    #!/usr/bin/env bash
    set -euox pipefail
    if docker ps --format '{{{{.Names}}' | grep -qx "{{container_name}}"; then
      echo "{{container_name}} is already running"
    elif docker ps -a --format '{{{{.Names}}' | grep -qx "{{container_name}}"; then
      docker build -t "{{image_name}}" -f "{{dockerfile}}" docker/postgres
      docker start "{{container_name}}"
    else
      docker run -d --name "{{container_name}}"
    fi
    echo "Waiting for PostgreSQL..."
    for _ in $(seq 1 60); do
      if command -v pg_isready >/dev/null 2>&1; then
        if PGPASSWORD="{{postgres_password}}" pg_isready -h localhost -p "{{postgres_port}}" -U "{{postgres_user}}" -d "{{postgres_db}}" >/dev/null 2>&1; then
          echo "PostgreSQL is ready"
          exit 0
        fi
      elif docker exec "{{container_name}}" pg_isready -U "{{postgres_user}}" -d "{{postgres_db}}" >/dev/null 2>&1; then
        echo "PostgreSQL is ready"
        exit 0
      fi
      sleep 1
    done
    echo "Timed out waiting for PostgreSQL" >&2
    exit 1

[private]
_psql-exec sql:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v psql >/dev/null 2>&1; then
      PGPASSWORD="{{postgres_password}}" psql -h localhost -p "{{postgres_port}}" -U "{{postgres_user}}" -d postgres -v ON_ERROR_STOP=1 -c "{{sql}}"
    else
      docker exec -e PGPASSWORD="{{postgres_password}}" "{{container_name}}" \
        psql -U "{{postgres_user}}" -d postgres -v ON_ERROR_STOP=1 -c "{{sql}}"
    fi
