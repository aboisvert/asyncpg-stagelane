# asyncpg-stagelane

Asynchronous PostgreSQL driver for Nim Language [http://www.nim-lang.org](http://nim-lang.org/)

## Main features

* Pure asynchronous implementation, based on LibPQ and Nim's async core
* Support for many SQL statements/results in one request
* Ability to send parameters separately from query, thus avoiding the need for tedious and error-prone quoting and escaping
* Automatic type conversion for basic Nim types
* Sending and receiving COPY data
* ARRAYS and JSON/JSONB support
* Asynchronous Notification

## Installation

You can use Nim official package manager `nimble` to install `asyncpg-stagelane`. The most recent version of the library can be installed via:

```
$ nimble install asyncpg-stagelane
```

To install from a local checkout of this repository:

```
$ nimble install .
```

## Minimal requirements

- PostgreSQL 9.x (if you want to have support for JSONB types, you need PostgreSQL 9.4 at least)
- Nim language compiler 0.14.2

## Usage

Import the package as `asyncpg_stagelane`:

```nim
import asyncpg_stagelane
```

## ToDo

* Add objects to automatic type conversion
* Add support for binary COPY data
