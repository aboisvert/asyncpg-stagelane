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

You can use Nim official package manager `nimble` to install `asyncpg-stagelane`. The most recent version of the library can be installed via:

```
$ nimble install asyncpg-stagelane
```

To install from a local checkout of this repository:

```
$ nimble install .
```

## Minimal requirements

- LibPQ (see Installation)
- PostgreSQL 9.x (if you want to have support for JSONB types, you need PostgreSQL 9.4 at least)
- Nim language compiler 0.14.2

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

Run the full suite (starts Postgres, compiles tests against the repo and the installed package, then runs everything — same flow as Appveyor):

```
$ just test
```

Or step by step: `just postgres-start`, then `just test-build`, then `just test-run`.

Other helpers:

| Command | Purpose |
|---------|---------|
| `just test-build` | Compile integration tests only |
| `just test-run` | Run compiled test binaries (expects `test-build` first) |
| `just postgres-stop` | Stop and remove the container |
| `just db-wipe` | Drop and recreate the `asyncpg` database (Postgres keeps running) |
| `just db-refresh` | Remove the container and start a fresh instance |

If port 5432 is already in use on your machine, stop the other service or change `postgres_port` in the [`justfile`](justfile).

## Usage

Import the package as `asyncpg_stagelane`:

```nim
import asyncpg_stagelane
```

## ToDo

* Add objects to automatic type conversion
* Add support for binary COPY data
