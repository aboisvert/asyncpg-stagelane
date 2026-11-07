## Integration test for `ApgSharedPool`: one pool shared across OS threads.
## Requires `-d:flowThreads --mm:atomicArc` (see test_shared_pool.nims).
import std/[strutils, times]
import stagelane
import asyncpg_stagelane
import asyncpg_stagelane/apg_shared_pool
import test_db

const
  BumpWorkers = 2
  PoolSize = 4
  BurstTasks = 16
  IncsPerWorker = 10
  SharedCounterTable = "shp_shared_ctr"
  NotifyChannel = "shp_ntf_ch"

var workerPool: ApgSharedPool

proc burstOne(pool: ApgSharedPool; ii: int) {.flow.} =
  var res = exec(pool, "SELECT $1::int", ii)
  let got = parseInt(getValue(res[0]))
  close(res)
  if got != ii:
    raise newException(ValueError, "burst wrong int")

proc burstWork(pool: ApgSharedPool) {.flow.} =
  var tasks = newSeq[Task[void]](BurstTasks)
  for i in 0 ..< BurstTasks:
    tasks[i] = go burstOne(pool, i)
  for t in tasks:
    waitDone(t)

proc setupSharedCounter(pool: ApgSharedPool) {.flow.} =
  var r = exec(pool, "DROP TABLE IF EXISTS " & SharedCounterTable)
  close(r)
  r = exec(pool,
    "CREATE TABLE " & SharedCounterTable & " (id int primary key, n bigint)")
  close(r)
  r = exec(pool, "INSERT INTO " & SharedCounterTable & " VALUES (1, 0)")
  close(r)

proc bumpSharedCounter(pool: ApgSharedPool) {.flow.} =
  for i in 0 ..< IncsPerWorker:
    withConnection(pool, conn) do:
      var r1 = exec(conn, "BEGIN")
      close(r1)
      var r2 = exec(conn, "UPDATE " & SharedCounterTable & " SET n = n + 1 WHERE id = 1")
      close(r2)
      var r3 = exec(conn, "COMMIT")
      close(r3)

proc verifySharedCounter(pool: ApgSharedPool; expect: int) {.flow.} =
  var r = exec(pool, "SELECT n FROM " & SharedCounterTable & " WHERE id = 1")
  let n = parseInt(getValue(r[0]))
  close(r)
  if n != expect:
    raise newException(ValueError, "counter expected " & $expect & " got " & $n)

proc leakOpenTxn(pool: ApgSharedPool) {.flow.} =
  withConnection(pool, conn) do:
    var r = exec(conn, "BEGIN")
    close(r)

proc assertCanQuery(pool: ApgSharedPool) {.flow.} =
  var r = exec(pool, "SELECT 1")
  close(r)

proc holdConnBriefly(pool: ApgSharedPool) {.flow.} =
  withConnection(pool, conn) do:
    var res = exec(conn, "SELECT pg_sleep(0.15)")
    close(res)

proc testGracefulClose(pool: ApgSharedPool) {.flow.} =
  let t = go holdConnBriefly(pool)
  yieldNow()
  close(pool)
  waitDone(t)
  try:
    discard checkout(pool)
    raise newException(AssertionDefect, "checkout after close should raise")
  except ApgSharedPoolClosedError:
    discard

proc senderNotify(pool: ApgSharedPool) {.flow.} =
  for i in 0 ..< 20:
    yieldNow()
  pool.sendNotify(NotifyChannel, "cross")

proc bumpThreadMain(pool: pointer) {.thread, nimcall.} =
  {.cast(gcsafe).}:
    run bumpSharedCounter(cast[ApgSharedPool](pool))

proc senderThreadMain(pool: pointer) {.thread, nimcall.} =
  {.cast(gcsafe).}:
    run senderNotify(cast[ApgSharedPool](pool))

proc main() =
  workerPool = newSharedPool(PoolSize)
  run workerPool.connect(connStr)
  run setupSharedCounter(workerPool)

  run burstWork(workerPool)

  let poolPtr = cast[pointer](workerPool)
  var bumpThreads: array[BumpWorkers, Thread[pointer]]
  for i in 0 ..< BumpWorkers:
    createThread(bumpThreads[i], bumpThreadMain, poolPtr)
  for i in 0 ..< BumpWorkers:
    joinThread(bumpThreads[i])

  run verifySharedCounter(workerPool, BumpWorkers * IncsPerWorker)

  run leakOpenTxn(workerPool)
  run assertCanQuery(workerPool)

  block:
    run workerPool.listenNotify(NotifyChannel)
    let w = workerPool.notify(NotifyChannel)
    var st: Thread[pointer]
    createThread(st, senderThreadMain, poolPtr)
    joinThread(st)
    let n = run waitNotify(w)
    if n.payload != "cross":
      raise newException(ValueError, "bad notify payload")
    run workerPool.unlistenNotify(NotifyChannel)

  block:
    var pool2 = newSharedPool(1)
    run pool2.connect(connStr)
    run testGracefulClose(pool2)

  close(workerPool)

main()
