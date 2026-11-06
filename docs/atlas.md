# Atlas dependency management

This repo requires Nim 2.2+ (`requires "nim >= 2.2.0"` in `asyncpg_stagelane.nimble`). It vendors Nim dependencies with [Atlas](https://github.com/nim-lang/atlas). Atlas clones each dependency into `deps/` as its own git checkout and writes `nim.cfg` so `nim c` finds them. There is no separate install step into `~/.nimble`.

Nim 2.2.12 bundles Atlas 0.14.7. The behavior below matches Atlas 0.16.2.

The files that define the graph:

| File | Role |
| --- | --- |
| `asyncpg_stagelane.nimble` | What to resolve. Atlas reads `requires` lines. |
| `deps/` | Checkouts. Gitignored. Recreated by Atlas. |
| `deps/atlas.config` | Atlas project settings (deps dir, overrides, resolver). Recreated on init. |
| `nim.cfg` | Compiler paths Atlas generates. Commit this. |
| `atlas.lock` | Pinned commits plus a snapshot of `nim.cfg` and the nimble file. Commit this. |

Current requirements:

```nim
requires "nim >= 2.2.0"
requires "db_connector"
requires "malebolgia >= 1.3.2"
requires "https://github.com/ghazalialshafi/stagelane#f72f1ea1cc603d6e00704988c18e496237617ac5"
```

`nim >= 2.2.0` is the Nimble spelling of the Nim 2.2+ requirement. Atlas checks it and does not clone a compiler. `db_connector` is a name in the Nimble package index, which Atlas maps to `https://github.com/nim-lang/db_connector`. `malebolgia` is also index-hosted (`https://github.com/Araq/malebolgia`). `stagelane` is absent from that index (`nimble search stagelane` finds nothing), so the requirement has to be a git URL.

## Day to day

```sh
atlas install          # resolve the nimble file and check out deps/
atlas install --update # fetch remote refs, then resolve
atlas pin              # write atlas.lock from the current checkouts
atlas rep              # check out the commits in atlas.lock
atlas deps             # show the selected graph
```

`just deps` is `atlas install`. `just test-build` depends on it, then compiles with `nim c`.

`atlas install` re-solves. The stagelane requirement names one commit, so a newer `main` does not move the checkout. `atlas rep` checks out the commits stored in `atlas.lock` and rewrites `nim.cfg` from the lock. It also rewrites `asyncpg_stagelane.nimble` from the copy stored in the lock, so pin again after editing the nimble file and before relying on `atlas rep`.

`atlas update` by itself only fetches refs. It prints a reminder to run `atlas install`.

## Stagelane is pinned to v0.2

Upstream's README calls commit `f72f1ea1cc603d6e00704988c18e496237617ac5` Version 0.2. That commit is not tagged, and `stagelane.nimble` still says `version = "0.1.0"`. Atlas turns versions into commits by reading tags, then by scanning nimble-file history. A requirement such as `>= 0.2.0` therefore matches nothing. A URL with no ref, `requires "https://github.com/ghazalialshafi/stagelane"`, also fails to select this commit: every commit after the `0.1.0` bump compares equal to `0.1.0` (build metadata does not participate in SemVer precedence), and the solver keeps the oldest, `4d7ed5d0`.

`#` followed by a commit hash is an exact pin. The requirement parser treats `#`, `<`, `=`, `>`, `^`, `~`, and `[` as the start of a version, so the form that works is:

```nim
requires "https://github.com/ghazalialshafi/stagelane#f72f1ea1cc603d6e00704988c18e496237617ac5"
```

The Nimble CLI spelling `url@#hash` is rejected. Atlas treats `@` as part of the package name, and a name whose path ends in `@` is an invalid requirement.

`atlas install` checks out that commit. `atlas.lock` records the same hash. Moving to a later stagelane release means editing this requirement, then running `atlas install` and `atlas pin`.

## Adding or replacing a git dependency

`atlas use <url>` initializes an Atlas project if needed, appends a `requires` line, clones, and regenerates `nim.cfg`.

It skips the nimble edit when it thinks the package is already required. The check is by short name, project name, and URL project name. An existing `requires "stagelane >= 0.1.0"` therefore counts as "already up to date", and `atlas use` will not replace that line with the git URL. Delete the name-based line first, then `atlas use https://github.com/ghazalialshafi/stagelane`, then replace the appended line with the pinned commit if the repo is untagged.

After the first `use`, edit the nimble file and run `atlas install` rather than `use` again.

## How the compiler finds the code

Atlas's whole integration with the compiler is `nim.cfg`:

```text
--noNimblePath
--path:"deps/db_connector/src"
--path:"deps/malebolgia/src"
--path:"deps/stagelane/src"
```

`--noNimblePath` drops `~/.nimble`, so the `db_connector` that ships inside the Nim toolchain is not the one that gets imported. The path entries point at each package's `srcDir`.

Nim loads `nim.cfg` / `config.nims` from the toolchain, then from the project file's directory and its parents. Compiling `tests/test_pool.nim` therefore sees:

- `asyncpg/nim.cfg` (Atlas paths)
- `asyncpg/config.nims` (includes `nimble.paths` only when that file exists; Atlas deletes it as obsolete)
- `tests/config.nims`

`tests/config.nims` keeps the package root on the path so `import asyncpg_stagelane` works:

```nim
switch("path", "$projectDir/../")
```

`nimble c` puts Nimble's package paths on the compiler command line, and command-line `--path` outranks `nim.cfg`. Test builds use `nim c` so the Atlas section is the one that wins. `just test-build` does that after `atlas install`.

## What to commit

`deps/*` are full git clones (and Atlas also keeps `deps/.cache`, `deps/_packages`, and sometimes `deps/.tmp`). Adding `deps/stagelane` to this repo would record a gitlink. `.gitignore` ignores all of `deps/`.

Commit `nim.cfg`, `atlas.lock`, and the `requires` lines. A fresh clone restores the tree with `atlas install` or `atlas rep`. `deps/atlas.config` is inside the ignored directory; the next Atlas command recreates it.
