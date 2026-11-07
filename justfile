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

# Open an interactive psql session on the test database.
# Connect inside the container so a local Postgres on port 5432 is not used.
psql: _postgres-ready
    docker exec -it "{{container_name}}" psql -U "{{postgres_user}}" -d "{{postgres_db}}"

# Clone Atlas dependencies into deps/ (stagelane from git, db_connector).
deps:
    atlas install

# Compile all integration tests.
# Uses `nim c` so nim.cfg's Atlas paths win over Nimble's global package dir.
test-build: deps
    #!/usr/bin/env bash
    set -euo pipefail
    tests=$(ls tests/*.nim | sed 's/\.nim//g')
    for test in $tests; do
      nim c "$test"
    done

# Run all integration test binaries.
# On macOS, libpq from Homebrew is keg-only. Honor DYLD_FALLBACK_LIBRARY_PATH
# when the developer set it; otherwise add "$(brew --prefix libpq)/lib".
test-run:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$(uname -s)" == Darwin ]] && command -v brew >/dev/null 2>&1; then
      libpq_lib="$(brew --prefix libpq)/lib"
      case ":${DYLD_FALLBACK_LIBRARY_PATH:-}:" in
        *":${libpq_lib}:"*) ;;
        *) export DYLD_FALLBACK_LIBRARY_PATH="${libpq_lib}${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}" ;;
      esac
    fi
    tests=(test_types test_pool test_rows test_notifies test_utils test_torture test_mt test_torture_mt test_shared_pool test_regressions)
    for name in "${tests[@]}"; do
      "tests/${name}"
    done

# Start Postgres, build, and run the full integration test suite.
test: _postgres-ready test-build test-run

[private]
_postgres-ready:
    #!/usr/bin/env bash
    set -euo pipefail
    if docker ps --format '{{{{.Names}}' | grep -qx "{{container_name}}"; then
      echo "{{container_name}} is already running"
    elif docker ps -a --format '{{{{.Names}}' | grep -qx "{{container_name}}"; then
      docker build -t "{{image_name}}" -f "{{dockerfile}}" docker/postgres
      docker start "{{container_name}}"
    else
      docker build -t "{{image_name}}" -f "{{dockerfile}}" docker/postgres
      docker run -d --name "{{container_name}}" -p "{{postgres_port}}:5432" "{{image_name}}"
    fi
    echo "Waiting for PostgreSQL..."
    for _ in $(seq 1 60); do
      if docker exec "{{container_name}}" pg_isready -U "{{postgres_user}}" -d "{{postgres_db}}" >/dev/null 2>&1; then
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
    docker exec "{{container_name}}" \
      psql -U "{{postgres_user}}" -d postgres -v ON_ERROR_STOP=1 -c "{{sql}}"
