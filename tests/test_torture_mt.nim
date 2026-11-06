## Multi-threaded torture: cross-thread Postgres state (shared counter) plus N
## independent workers each running `torture_lib.runTortureSuite` on its own
## connection and pool (no sharing across threads).
import std/[strutils, times]
import malebolgia except cancel
import stagelane, asyncpg_stagelane, test_db
import torture_lib

const
  NThreads = 4
  SharedIncsPerThread = 15

## Malebolgia `createMaster(timeout=...)` caps wall time for `awaitAll` on the main
## thread's event loop. Do not rely on stagelane `waitFor` for per-scenario caps
## inside worker threads: each OS thread has a separate scheduler/timer wheel, and
## under contention inner timers can fire too early (false "timeout: ..."). The MT
## suite uses `runTortureSuite(..., innerTimeouts = false)` and waits only with
## `waitDone`; see `tests/torture_lib.nim` (`runTortureSuite`).
const
  MbBumpMasterTimeout = initDuration(minutes = 2)
  MbPerThreadTortureMasterTimeout = initDuration(minutes = 12)

proc mtKnobs(workerId: int): TortureKnobs =
  ## Smaller load than `test_torture.nim`; table/channel names must be unique per worker.
  result = defaultTortureKnobs()
  result.poolSize = 2
  result.saturationTasks = 10
  result.errStormTasks = 10
  result.shortSleepSec = "0.05"
  result.holderSleepSec = "0.15"
  result.cancelHolderSleepSec = "2"
  result.counterTable = "mt_ctr_" & $workerId
  result.notifyChannel = "mt_ntf_" & $workerId
  result.noiseStopAfter = 30
  result.counterIncs = 20

proc perThreadBody(workerId: int; connStr: string) {.flow.} =
  ## One standalone connection (NOTIFY half of the suite) plus a private pool.
  var conn = connect(connStr)
  let k = mtKnobs(workerId)
  let pool = newPool(k.poolSize)
  connect(pool, connStr)
  runTortureSuite(conn, pool, k, innerTimeouts = false)
  close(pool)
  close(conn)

proc perThreadTorture(workerId: int; connStr: string) {.gcsafe.} =
  ## Malebolgia `spawn` requires gcsafe; `run` is not, so we narrow the cast to this call.
  {.cast(gcsafe).}:
    run perThreadBody(workerId, connStr)

proc setupSharedCounter(connStr: string) {.flow.} =
  var c = connect(connStr)
  var r = exec(c, "DROP TABLE IF EXISTS mt_shared_ctr")
  close(r)
  r = exec(c, "CREATE TABLE mt_shared_ctr (id int primary key, n bigint not null)")
  close(r)
  r = exec(c, "INSERT INTO mt_shared_ctr VALUES (1, 0)")
  close(r)
  close(c)

proc bumpSharedCounter(connStr: string) {.flow.} =
  var pool = newPool(2)
  connect(pool, connStr)
  for i in 0 ..< SharedIncsPerThread:
    withConnection(pool, conn) do:
      var r1 = exec(conn, "BEGIN")
      close(r1)
      var r2 = exec(conn, "UPDATE mt_shared_ctr SET n = n + 1 WHERE id = 1")
      close(r2)
      var r3 = exec(conn, "COMMIT")
      close(r3)
  close(pool)

proc verifySharedCounter(connStr: string) {.flow.} =
  var c = connect(connStr)
  var r = exec(c, "SELECT n FROM mt_shared_ctr WHERE id = 1")
  let n = parseInt(getValue(r[0]))
  close(r)
  if n != NThreads * SharedIncsPerThread:
    raise newException(ValueError, "mt shared counter: " & $n)
  r = exec(c, "DROP TABLE mt_shared_ctr")
  close(r)
  close(c)

proc runCrossThreadCounter(connStr: string) =
  ## Main thread sets up `mt_shared_ctr`, then malebolgia bumps from N workers with
  ## separate pools; final count must equal `NThreads * SharedIncsPerThread`.
  {.cast(gcsafe).}:
    run setupSharedCounter(connStr)

  proc bump(c: string) {.gcsafe.} =
    ## Closed-over name `bump` for `m.spawn bump(connStr)` (passes connection string into worker).
    {.cast(gcsafe).}:
      run bumpSharedCounter(c)

  block:
    var m = createMaster(timeout = MbBumpMasterTimeout)
    m.awaitAll:
      for i in 0 ..< NThreads:
        m.spawn bump(connStr)

  {.cast(gcsafe).}:
    run verifySharedCounter(connStr)

proc main() =
  runCrossThreadCounter(connStr)
  var m = createMaster(timeout = MbPerThreadTortureMasterTimeout)
  m.awaitAll:
    for i in 0 ..< NThreads:
      m.spawn perThreadTorture(i, connStr)

main()
