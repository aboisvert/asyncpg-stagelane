import std/[sets, strutils]
import stagelane, asyncpg_stagelane

type
  TortureKnobs* = object
    poolSize*: int
    saturationTasks*: int
    errStormTasks*: int
    globalTimeoutMs*: int
    shortSleepSec*: string
    holderSleepSec*: string
    cancelHolderSleepSec*: string
    counterTable*: string
    notifyChannel*: string
    noiseStopAfter*: int
    counterIncs*: int

proc defaultTortureKnobs*(): TortureKnobs =
  TortureKnobs(
    poolSize: 4,
    saturationTasks: 40,
    errStormTasks: 30,
    globalTimeoutMs: 120_000,
    shortSleepSec: "0.35",
    holderSleepSec: "3",
    cancelHolderSleepSec: "60",
    counterTable: "torture_counter",
    notifyChannel: "torture_notify_ch",
    noiseStopAfter: 200,
    counterIncs: 80,
  )

proc withTimeout*(t: TaskBase, knobs: TortureKnobs, scenario: string) =
  if not waitFor(t, knobs.globalTimeoutMs):
    raise newException(ValueError, "timeout: " & scenario)

proc selInt1*(pool: ApgPool, q: string, a: int): int {.flow.} =
  var res = exec(pool, q, a)
  result = parseInt(getValue(res[0]))
  close(res)

proc selInt0*(pool: ApgPool, q: string): int {.flow.} =
  var res = exec(pool, q)
  result = parseInt(getValue(res[0]))
  close(res)

proc selOptText*(pool: ApgPool, q: string): string {.flow.} =
  var res = exec(pool, q)
  result = getValue(res[0])
  close(res)

proc saturationWorker(pool: ApgPool, knobs: TortureKnobs, expected: int) {.flow.} =
  let got = selInt1(pool, "SELECT $1::int", expected)
  if got != expected:
    raise newException(ValueError, "saturation wrong value")

proc runSaturation*(pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  var tasks = newSeq[Task[void]](knobs.saturationTasks)
  for i in 0 ..< knobs.saturationTasks:
    tasks[i] = go saturationWorker(pool, knobs, i + 1)
  for t in tasks:
    waitDone(t)

type
  PidSeen = ref object
    cur: HashSet[int]

proc newPidSeen(): PidSeen =
  PidSeen(cur: initHashSet[int]())

proc pidOnceWorker(seen: PidSeen, pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  let pid = selInt0(pool, "SELECT pg_backend_pid()::int")
  if pid in seen.cur:
    raise newException(ValueError, "pid overlap / double checkout")
  seen.cur.incl(pid)
  block:
    let dur = knobs.shortSleepSec
    var res = exec(pool, "SELECT pg_sleep($1)", dur)
    close(res)
  seen.cur.excl(pid)

proc runPidUniqueness*(pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  let seen = newPidSeen()
  var tasks = newSeq[Task[void]](knobs.saturationTasks)
  for i in 0 ..< knobs.saturationTasks:
    tasks[i] = go pidOnceWorker(seen, pool, knobs)
  for t in tasks:
    waitDone(t)

proc errStormWorker(pool: ApgPool, knobs: TortureKnobs, i: int) {.flow.} =
  if i mod 4 == 0:
    try:
      var res = exec(pool, "SELECT 1 / 0")
      close(res)
      raise newException(ValueError, "expected div0")
    except CatchableError:
      discard
  else:
    let got = selInt1(pool, "SELECT $1::int", i)
    if got != i:
      raise newException(ValueError, "errStorm bad value")

proc runErrStorm*(pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  var tasks = newSeq[Task[void]](knobs.errStormTasks)
  for i in 0 ..< knobs.errStormTasks:
    tasks[i] = go errStormWorker(pool, knobs, i)
  for t in tasks:
    waitDone(t)
  if selInt0(pool, "SELECT 1") != 1:
    raise newException(ValueError, "errStorm follow-up SELECT 1")
  if selOptText(pool, "SELECT txid_current_if_assigned()::text") != "":
    raise newException(ValueError, "aborted xact leaked")

proc sleepForever(pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  block:
    let dur = knobs.cancelHolderSleepSec
    var res = exec(pool, "SELECT pg_sleep($1)", dur)
    close(res)

proc runCancelHolders*(pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  var holders = newSeq[Task[void]](knobs.poolSize)
  for i in 0 ..< knobs.poolSize:
    holders[i] = go sleepForever(pool, knobs)
  yieldNow()
  yieldNow()
  for h in holders:
    cancel(h.TaskBase)
  for h in holders:
    waitDone(h)
    if not cancelled(h.TaskBase):
      raise newException(ValueError, "holder not cancelled")
  if selInt0(pool, "SELECT 1") != 1:
    raise newException(ValueError, "cancel holders: pool dead")

proc shortQuery(pool: ApgPool) {.flow.} =
  var res = exec(pool, "SELECT 1")
  close(res)

proc holdSlot(pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  block:
    let dur = knobs.holderSleepSec
    var res = exec(pool, "SELECT pg_sleep($1)", dur)
    close(res)

proc runCancelWaiters*(pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  var holders = newSeq[Task[void]](knobs.poolSize)
  for i in 0 ..< knobs.poolSize:
    holders[i] = go holdSlot(pool, knobs)
  yieldNow()
  yieldNow()
  var waiters = newSeq[Task[void]](knobs.poolSize)
  for i in 0 ..< knobs.poolSize:
    waiters[i] = go shortQuery(pool)
  yieldNow()
  for w in waiters:
    cancel(w.TaskBase)
  for w in waiters:
    waitDone(w)
    if not cancelled(w.TaskBase):
      raise newException(ValueError, "waiter not cancelled")
  for h in holders:
    cancel(h.TaskBase)
  for h in holders:
    waitDone(h)
  if selInt0(pool, "SELECT 2") != 2:
    raise newException(ValueError, "cancel waiters: pool dead")

proc bumpCounter(pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  withConnection(pool, conn) do:
    var r1 = exec(conn, "BEGIN")
    close(r1)
    var r2 = exec(conn, "UPDATE " & knobs.counterTable &
      " SET n = n + 1 WHERE id = 1")
    close(r2)
    var r3 = exec(conn, "COMMIT")
    close(r3)

proc runCounter*(pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  block:
    var res = exec(pool, "DROP TABLE IF EXISTS " & knobs.counterTable)
    close(res)
  block:
    var res = exec(pool, "CREATE TABLE " & knobs.counterTable &
      " (id int primary key, n bigint not null)")
    close(res)
  block:
    var res = exec(pool, "INSERT INTO " & knobs.counterTable & " VALUES (1, 0)")
    close(res)
  var tasks = newSeq[Task[void]](knobs.counterIncs)
  for i in 0 ..< knobs.counterIncs:
    tasks[i] = go bumpCounter(pool, knobs)
  for t in tasks:
    waitDone(t)
  let finalN = selInt0(pool, "SELECT n FROM " & knobs.counterTable &
    " WHERE id = 1")
  if finalN != knobs.counterIncs:
    raise newException(ValueError, "counter mismatch: " & $finalN)
  block:
    var res = exec(pool, "DROP TABLE IF EXISTS " & knobs.counterTable)
    close(res)

proc noiseWorker(pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  var k = 0
  while k < knobs.noiseStopAfter:
    discard selInt1(pool, "SELECT $1::int", k)
    inc k

proc recvPayload(w: NotifyWait, expected: string) {.flow.} =
  let n = waitNotify(w)
  if n.payload != expected:
    raise newException(ValueError, "notify payload mismatch")

proc runNotifyStress*(conn: ApgConnection, pool: ApgPool, knobs: TortureKnobs) {.flow.} =
  let noise = go noiseWorker(pool, knobs)
  listenNotify(conn, knobs.notifyChannel)
  block:
    let w1 = notify(conn, knobs.notifyChannel)
    let w2 = notify(conn, knobs.notifyChannel)
    let w3 = notify(conn, knobs.notifyChannel)
    let pay = "conn-bundle"
    let t1 = go recvPayload(w1, pay)
    let t2 = go recvPayload(w2, pay)
    let t3 = go recvPayload(w3, pay)
    yieldNow()
    sendNotify(conn, knobs.notifyChannel, pay)
    waitDone(t1)
    waitDone(t2)
    waitDone(t3)

  listenNotify(pool, knobs.notifyChannel)
  block:
    let w1 = notify(pool, knobs.notifyChannel)
    let w2 = notify(pool, knobs.notifyChannel)
    let pay = "pool-bundle"
    let t1 = go recvPayload(w1, pay)
    let t2 = go recvPayload(w2, pay)
    yieldNow()
    sendNotify(conn, knobs.notifyChannel, pay)
    for _ in 0 ..< knobs.poolSize:
      discard selInt0(pool, "SELECT 1")
    waitDone(t1)
    waitDone(t2)

  unlistenNotify(conn, knobs.notifyChannel)
  unlistenNotify(pool, knobs.notifyChannel)
  cancel(noise.TaskBase)
  waitDone(noise)

proc runTortureSuite*(conn: ApgConnection, pool: ApgPool, knobs: TortureKnobs;
    innerTimeouts = true) {.flow.} =
  ## When `innerTimeouts` is true (single-threaded `test_torture`), each scenario is
  ## wrapped in `withTimeout` so a lost wakeup fails fast. When false (e.g.
  ## `test_torture_mt` on a malebolgia worker thread), use only `waitDone`: stagelane
  ## `waitFor` is per-thread scheduler and can false-positive under OS-thread load.
  template runScenario(scenario: string; body: typed) =
    block:
      let t = go body
      if innerTimeouts:
        withTimeout(t.TaskBase, knobs, scenario)
      else:
        waitDone(t)

  runScenario("saturation"):
    runSaturation(pool, knobs)
  runScenario("pid uniqueness"):
    runPidUniqueness(pool, knobs)
  runScenario("err storm"):
    runErrStorm(pool, knobs)
  runScenario("cancel holders"):
    runCancelHolders(pool, knobs)
  runScenario("cancel waiters"):
    runCancelWaiters(pool, knobs)
  runScenario("counter"):
    runCounter(pool, knobs)
  runScenario("notify stress"):
    runNotifyStress(conn, pool, knobs)

when isMainModule:
  discard
