# asyncpg-stagelane

Asynchronous PostgreSQL driver for [Nim](http://www.nim-lang.org/).

This project is a fork of [asyncpg](https://github.com/cheatfate/asyncpg) (Eugene Kabanov’s asynchronous LibPQ driver). **asyncpg-stagelane** exists to port that driver onto the [stagelane](https://github.com/ghazalialshafi/stagelane) async runtime instead of Nim’s standard `asyncdispatch` stack, while preserving the same PostgreSQL-focused API.

## Main features

* Pure asynchronous implementation, based on LibPQ
* Support for many SQL statements/results in one request
* Ability to send parameters separately from query, thus avoiding the need for tedious and error-prone quoting and escaping
* Automatic type conversion for basic Nim types
* Sending and receiving COPY data
* ARRAYS and JSON/JSONB support
* Asynchronous Notification

## Installation

Install LibPQ first:

**macOS**

```
$ brew install libpq
```

**Linux (Debian)**

```
$ sudo apt-get install libpq libpq-dev pkg-config
```

Requires Nim 2.2+. Dependencies are vendored with [Atlas](https://github.com/nim-lang/atlas) into `deps/`. [stagelane](https://github.com/ghazalialshafi/stagelane) is not on the Nimble package index. This repo pins stagelane v0.2 by commit (`f72f1ea1`), because that release has no git tag and its nimble file still says `0.1.0`. `atlas.lock` records the same commit.

```
$ atlas install
```

`atlas rep` checks out the commits in `atlas.lock`.

## Minimal requirements

- LibPQ (see Installation)
- PostgreSQL 9.x (if you want to have support for JSONB types, you need PostgreSQL 9.4 at least)
- Nim 2.2+ (`requires "nim >= 2.2.0"`)
- [stagelane](https://github.com/ghazalialshafi/stagelane), vendored by Atlas from its git repository (`atlas install`)

This driver uses stagelane’s POSIX event loop (`waitReadable` / `waitWritable` on the libpq socket). Use each connection or pool only on the thread whose stagelane scheduler is driving I/O.

## Integration tests

The test suite under `tests/` needs a PostgreSQL database named `asyncpg`, reachable as user `postgres`. For local development you can run the latest PostgreSQL in Docker (see [`docker/postgres/Dockerfile`](docker/postgres/Dockerfile)).

Requirements: [Docker](https://docs.docker.com/get-docker/) and [just](https://github.com/casey/just).

Start the database (builds the image on first run, publishes port 5432):

```
$ just postgres-start
```

`just` recipes export `ASYNCPG_DB` with the test password so the tests connect correctly. Run recipes from the repo root (or set the same variable yourself):

```
host=localhost port=5432 dbname=asyncpg user=postgres password=postgres
```

Run the full suite (starts Postgres, vendors dependencies with Atlas, compiles tests, then runs them):

```
$ just test
```

Or step by step: `just postgres-start`, then `just test-build`, then `just test-run`.

Other helpers:

| Command | Purpose |
|---------|---------|
| `just deps` | Clone Atlas dependencies into `deps/` |
| `just test-build` | Compile integration tests (`atlas install`, then `nim c`) |
| `just test-run` | Run compiled test binaries (expects `test-build` first) |
| `just postgres-stop` | Stop and remove the container |
| `just db-wipe` | Drop and recreate the `asyncpg` database (Postgres keeps running) |
| `just db-refresh` | Remove the container and start a fresh instance |
| `just psql` | Open an interactive `psql` session on the `asyncpg` database |

If port 5432 is already in use on your machine, stop the other service or change `postgres_port` in the [`justfile`](justfile).

## Usage

Import this package together with stagelane. Suspending APIs are `{.flow.}` procs: call them from other flow code, or from `main` via `run`, which drives the event loop until the call finishes.

```nim
import stagelane
import asyncpg_stagelane

proc app(connStr: string) {.flow.} =
  let conn = connect(connStr)
  defer: close(conn)
  var res = exec(conn, "SELECT 1;")
  defer: close(res)
  echo getValue(res[0])

run app("host=... port=5432 dbname=... user=... password=...")
```

Overlapping queries use `go` and `await` on `Task` handles:

```nim
proc long(pool: apgPool) {.flow.} =
  var r = exec(pool, "SELECT pg_sleep(1);")
  close(r)

proc main(pool: apgPool) {.flow.} =
  let t = go long(pool)
  # ... other work ...
  await t

run main(myPool)
```

LISTEN/NOTIFY: register a waiter with `notify`, send with `sendNotify`, then wait in a child task and use `waitFor` for a timeout (same pattern as the integration tests):

```nim
proc waitOnce(conn: apgConnection) {.flow.} =
  listenNotify(conn, "ch")
  let w = notify(conn, "ch")
  sendNotify(conn, "ch", "hello")
  discard waitFor(go waitNotify(w), 100)
  unlistenNotify(conn, "ch")
```

## ToDo

* Add objects to automatic type conversion
* Add support for binary COPY data
