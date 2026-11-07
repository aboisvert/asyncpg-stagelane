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

This driver uses stagelane’s POSIX event loop (`waitReadable` / `waitWritable` on the libpq socket). Each connection, `apgPool`, and task stays on the thread that created it; only `apgSharedPool` can be shared across threads. See [Pool implementations](#pool-implementations) and [Threads](#threads).

## Pool implementations

asyncpg-stagelane has two connection pools:

| | `apgPool` | `apgSharedPool` |
|---|---|---|
| Intended use | Single-threaded: one pool per OS thread | Multi-threaded: one pool shared by tasks on many OS threads |
| Import | `asyncpg_stagelane` | `asyncpg_stagelane/apg_shared_pool` |
| Create | `newPool(size)` | `newSharedPool(size)` |
| Locking | None (no overhead) | Internal lock around pool bookkeeping |
| Build flags | Default | `--threads:on --mm:atomicArc -d:flowThreads` |
| Close | `close(pool)` | `close(pool)` (graceful: idle connections closed now, busy ones at checkin) |

Both support `connect`, `exec`, `withConnection`, `listenNotify` / `sendNotify` / `notify`. Each connection is still used by one task at a time. Choose `apgPool` unless you need to share a pool across threads. See [Threads](#threads) for details and [docs/shared-pool-flowthreads.md](docs/shared-pool-flowthreads.md) for why the shared pool needs `-d:flowThreads`.

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

## Threads

Many OS threads can use the driver at once. Each thread owns the objects it creates. `apgPool` keeps its slot flags, wait queue, and notify list without locks, and libpq allows only one thread to use a given `PGconn` at a time. The stagelane scheduler is thread-local: `run` drives that thread’s event loop, and a socket wait is registered only on that loop.

### Shared pool across threads (`apgSharedPool`)

To check out connections from one pool on several OS threads, import [`asyncpg_stagelane/apg_shared_pool`](asyncpg_stagelane/apg_shared_pool.nim) and build with `--threads:on --mm:atomicArc -d:flowThreads`. Stagelane must route task wakeups across threads in this mode; plain ARC/ORC is not enough for handles that cross thread boundaries.

Each `PGconn` still has a single borrower at a time: checkout hands a connection to one task, checkin returns it. Socket waits run on the borrowing thread and are cleared before checkin, so the next borrower may be on another thread. Do not stash an `apgConnection` from `withConnection` past the end of the block.

On checkin, connections that are broken or not idle at the SQL session level (open transaction, etc.) are dropped and replaced lazily on the next checkout. `close(pool)` marks the pool closed, fails new checkouts, closes idle slots immediately, and closes busy slots when they are returned.

`listenNotify` on a pool still runs `LISTEN` on only the connection checked out for that call; other slots are unaffected.

```nim
import asyncpg_stagelane/apg_shared_pool

proc work(pool: apgSharedPool) {.flow.} =
  var res = exec(pool, "SELECT 1")
  defer: close(res)

proc worker(pool: apgSharedPool) {.gcsafe.} =
  {.cast(gcsafe).}:
    run work(pool)

let pool = newSharedPool(4)
run pool.connect(connStr)
# share `pool` with malebolgia / createThread workers, then close(pool)
```

Keep all of these on the thread that created them, and close connections and pools before that thread returns (for plain `apgPool` / `apgConnection` — not `apgSharedPool`, which is designed to be shared):

* `apgConnection` and `apgPool`, including every connection stored in the pool
* `apgResult`
* `NotifyWait`
* stagelane `Task` handles (`await`, `waitDone`, `waitFor`)

`apgPool` and `apgConnection` leave `-d:flowThreads` unused: they never post a connection, pool, or task to another scheduler. Only `apgSharedPool` requires it.

Pass a connection string into the worker and open the pool inside `run`. `run` is not `{.gcsafe.}`, so a spawn proc (`createThread`, malebolgia, and similar) needs a narrow cast around that call:

```nim
proc work(connStr: string) {.flow.} =
  let pool = newPool(4)
  connect(pool, connStr)
  defer: close(pool)
  var res = exec(pool, "SELECT 1;")
  defer: close(res)

proc worker(connStr: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    run work(connStr)
```

Nim strings, integers, and other values already copied out of a result (`getValue`, `getRow`) are ordinary data and can move to another thread. Share database state through SQL. A counter updated from several threads belongs in a transaction (`BEGIN` / `UPDATE` / `COMMIT`) on each thread’s own pool. For NOTIFY across threads, give each side its own connection: the listener must `listenNotify` before the others `sendNotify`, because PostgreSQL drops a notification for a session that is not yet listening.

Each thread has its own timer wheel, so `waitFor` only sees that thread. Under load from many OS threads it can time out while the task is still running. Use `waitDone` when the task has to finish, and put the wall-clock cap on the thread pool (malebolgia’s `createMaster` timeout, for example).

On one thread, a connection runs one libpq operation at a time. A second `exec`, `reset`, `copyTo`, or `copyFromInto` on the same `apgConnection` while another is suspended is undefined: the scheduler accepts one reader and one writer per socket, and libpq will not run two commands on one connection. Overlap queries through the pool. `exec` on a pool and `withConnection` each check out one slot, and several `go` tasks may share that pool, up to its size. Finish those tasks before `close`. A connection taken with `withConnection` stays inside that block.

`notify` / `waitNotify` park on that same thread. Payloads are read only while the listening connection is inside `exec` or COPY, so a waiter makes progress only when that connection is running an operation. `listenNotify` on a pool issues `LISTEN` on the one connection it checks out, so the other slots in the pool are not listening.

## ToDo

* Add objects to automatic type conversion
* Add support for binary COPY data
