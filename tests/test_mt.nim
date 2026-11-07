## Multi-threaded smoke test: malebolgia `spawn`s N workers on the pool; each worker
## runs `run burstWork(...)` so it gets its own stagelane scheduler thread-locally.
## Never share an `ApgPool` or `ApgConnection` across OS threads (libpq and our pool
## are not synchronized). For a thread-safe pool across workers, use `ApgSharedPool`
## (`import asyncpg_stagelane/apg_shared_pool`; see `tests/test_shared_pool.nim`).
## `import malebolgia except cancel` avoids clashing with stagelane's task `cancel`.
import std/[strutils, times]
import malebolgia except cancel
import stagelane, asyncpg_stagelane, test_db

const
  NThreads = 4
  PoolSize = 4
  BurstTasks = 16
  ## If workers deadlock, `awaitAll` raises after this wall-clock budget instead of hanging CI.
  MbBurstMasterTimeout = initDuration(minutes = 2)

proc burstOne(pool: ApgPool; ii: int) {.flow.} =
  var res = exec(pool, "SELECT $1::int", ii)
  let got = parseInt(getValue(res[0]))
  close(res)
  if got != ii:
    raise newException(ValueError, "test_mt wrong int")

proc burstWork(connStr: string) {.flow.} =
  var conn = connect(connStr)
  block:
    var res = exec(conn, "SELECT 1")
    close(res)
  var pool = newPool(PoolSize)
  connect(pool, connStr)
  var tasks = newSeq[Task[void]](BurstTasks)
  for i in 0 ..< BurstTasks:
    tasks[i] = go burstOne(pool, i)
  for t in tasks:
    waitDone(t)
  close(pool)
  close(conn)

proc burstWorker(connStr: string) {.gcsafe.} =
  ## `run` / `runTask` is not marked gcsafe; malebolgia requires gcsafe spawns.
  {.cast(gcsafe).}:
    run burstWork(connStr)

proc main() =
  var m = createMaster(timeout = MbBurstMasterTimeout)
  m.awaitAll:
    for i in 0 ..< NThreads:
      m.spawn burstWorker(connStr)

main()
