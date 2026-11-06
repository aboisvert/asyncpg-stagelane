import std/[sets, strutils]
import stagelane, asyncpg_stagelane, test_db

# Knobs: keep total wall time modest for `just test`.
const
  PoolSize = 4
  SaturationTasks = 40
  GlobalTimeoutMs = 120_000
  ShortSleepSec = "0.35"
  HolderSleepSec = "3"
  CancelHolderSleepSec = "60"
  ErrStormTasks = 30

proc withTimeout(t: TaskBase, scenario: string) =
  if not waitFor(t, GlobalTimeoutMs):
    raise newException(ValueError, "timeout: " & scenario)

proc selInt1(pool: apgPool, q: string, a: int): int {.flow.} =
  var res = exec(pool, q, a)
  result = parseInt(getValue(res[0]))
  close(res)

proc selInt0(pool: apgPool, q: string): int {.flow.} =
  var res = exec(pool, q)
  result = parseInt(getValue(res[0]))
  close(res)

proc selOptText(pool: apgPool, q: string): string {.flow.} =
  var res = exec(pool, q)
  result = getValue(res[0])
  close(res)

# --- 1. Saturation: many tasks interleave on checkout; each sees its own param.
proc saturationWorker(pool: apgPool, expected: int) {.flow.} =
  let got = selInt1(pool, "SELECT $1::int", expected)
  if got != expected:
    raise newException(ValueError, "saturation wrong value")

proc runSaturation(pool: apgPool) {.flow.} =
  var tasks = newSeq[Task[void]](SaturationTasks)
  for i in 0 ..< SaturationTasks:
    tasks[i] = go saturationWorker(pool, i + 1)
  for t in tasks:
    waitDone(t)

# --- 2. At most poolSize backend PIDs in flight; no duplicate checkout.
type
  PidSeen = ref object
    cur: HashSet[int]

proc newPidSeen(): PidSeen =
  PidSeen(cur: initHashSet[int]())

proc pidOnceWorker(seen: PidSeen, pool: apgPool) {.flow.} =
  let pid = selInt0(pool, "SELECT pg_backend_pid()::int")
  if pid in seen.cur:
    raise newException(ValueError, "pid overlap / double checkout")
  seen.cur.incl(pid)
  # Stay checked out across yields so multiple PIDs should be in flight.
  block:
    let dur = ShortSleepSec
    var res = exec(pool, "SELECT pg_sleep($1)", dur)
    close(res)
  seen.cur.excl(pid)

proc runPidUniqueness(pool: apgPool) {.flow.} =
  let seen = newPidSeen()
  var tasks = newSeq[Task[void]](SaturationTasks)
  for i in 0 ..< SaturationTasks:
    tasks[i] = go pidOnceWorker(seen, pool)
  for t in tasks:
    waitDone(t)

# --- 3. Error storm: failed query kills slot; follow-up must reconnect and work.
proc errStormWorker(pool: apgPool, i: int) {.flow.} =
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

proc runErrStorm(pool: apgPool) {.flow.} =
  var tasks = newSeq[Task[void]](ErrStormTasks)
  for i in 0 ..< ErrStormTasks:
    tasks[i] = go errStormWorker(pool, i)
  for t in tasks:
    waitDone(t)
  if selInt0(pool, "SELECT 1") != 1:
    raise newException(ValueError, "errStorm follow-up SELECT 1")
  if selOptText(pool, "SELECT txid_current_if_assigned()::text") != "":
    raise newException(ValueError, "aborted xact leaked")

# --- 4. Cancel tasks that hold connections; pool must recover.
proc sleepForever(pool: apgPool) {.flow.} =
  block:
    let dur = CancelHolderSleepSec
    var res = exec(pool, "SELECT pg_sleep($1)", dur)
    close(res)

proc runCancelHolders(pool: apgPool) {.flow.} =
  var holders = newSeq[Task[void]](PoolSize)
  for i in 0 ..< PoolSize:
    holders[i] = go sleepForever(pool)
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

# --- 5. Cancel tasks waiting in pool queue (checkout park), not holders.
proc shortQuery(pool: apgPool) {.flow.} =
  var res = exec(pool, "SELECT 1")
  close(res)

proc holdSlot(pool: apgPool) {.flow.} =
  block:
    let dur = HolderSleepSec
    var res = exec(pool, "SELECT pg_sleep($1)", dur)
    close(res)

proc runCancelWaiters(pool: apgPool) {.flow.} =
  var holders = newSeq[Task[void]](PoolSize)
  for i in 0 ..< PoolSize:
    holders[i] = go holdSlot(pool)
  yieldNow()
  yieldNow()
  ## One short query per slot: each should block in checkout while holders sleep.
  var waiters = newSeq[Task[void]](PoolSize)
  for i in 0 ..< PoolSize:
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

proc bumpCounter(pool: apgPool) {.flow.} =
  withConnection(pool, conn) do:
    var r1 = exec(conn, "BEGIN")
    close(r1)
    var r2 = exec(conn, "UPDATE torture_counter SET n = n + 1 WHERE id = 1")
    close(r2)
    var r3 = exec(conn, "COMMIT")
    close(r3)

# --- 6. Serialized increments through row locks.
proc runCounter(pool: apgPool) {.flow.} =
  block:
    var res = exec(pool, "DROP TABLE IF EXISTS torture_counter")
    close(res)
  block:
    var res = exec(pool, "CREATE TABLE torture_counter (id int primary key, n bigint not null)")
    close(res)
  block:
    var res = exec(pool, "INSERT INTO torture_counter VALUES (1, 0)")
    close(res)
  const nIncs = 80
  var tasks = newSeq[Task[void]](nIncs)
  for i in 0 ..< nIncs:
    tasks[i] = go bumpCounter(pool)
  for t in tasks:
    waitDone(t)
  let finalN = selInt0(pool, "SELECT n FROM torture_counter WHERE id = 1")
  if finalN != nIncs:
    raise newException(ValueError, "counter mismatch: " & $finalN)
  block:
    var res = exec(pool, "DROP TABLE torture_counter")
    close(res)

# --- 7. NOTIFY under load: connection path (multiple waiters) + pool path.
const NotifyChannel = "torture_notify_ch"

proc noiseWorker(pool: apgPool, stopAfter: int) {.flow.} =
  var k = 0
  while k < stopAfter:
    discard selInt1(pool, "SELECT $1::int", k)
    inc k

proc recvPayload(w: NotifyWait, expected: string) {.flow.} =
  let n = waitNotify(w)
  if n.payload != expected:
    raise newException(ValueError, "notify payload mismatch")

proc runNotifyStress(conn: apgConnection, pool: apgPool) {.flow.} =
  let noise = go noiseWorker(pool, 200)
  listenNotify(conn, NotifyChannel)
  # Connection: three waiters on one channel for one payload.
  block:
    let w1 = notify(conn, NotifyChannel)
    let w2 = notify(conn, NotifyChannel)
    let w3 = notify(conn, NotifyChannel)
    let pay = "conn-bundle"
    let t1 = go recvPayload(w1, pay)
    let t2 = go recvPayload(w2, pay)
    let t3 = go recvPayload(w3, pay)
    yieldNow()
    # NOTIFY must be read on the listening connection (`conn`); pool send would skip it.
    sendNotify(conn, NotifyChannel, pay)
    waitDone(t1)
    waitDone(t2)
    waitDone(t3)

  listenNotify(pool, NotifyChannel)
  block:
    let w1 = notify(pool, NotifyChannel)
    let w2 = notify(pool, NotifyChannel)
    let pay = "pool-bundle"
    let t1 = go recvPayload(w1, pay)
    let t2 = go recvPayload(w2, pay)
    yieldNow()
    sendNotify(conn, NotifyChannel, pay)
    # The LISTEN runs on one pool connection; cycle every slot so that listener drains NOTIFY.
    for _ in 0 ..< PoolSize:
      discard selInt0(pool, "SELECT 1")
    waitDone(t1)
    waitDone(t2)

  unlistenNotify(conn, NotifyChannel)
  unlistenNotify(pool, NotifyChannel)
  cancel(noise.TaskBase)
  waitDone(noise)

proc main(conn: apgConnection) {.flow.} =
  let p = newPool(PoolSize)
  connect(p, connStr)

  block:
    let t = go runSaturation(p)
    withTimeout(t.TaskBase, "saturation")
  block:
    let t = go runPidUniqueness(p)
    withTimeout(t.TaskBase, "pid uniqueness")
  block:
    let t = go runErrStorm(p)
    withTimeout(t.TaskBase, "err storm")
  block:
    let t = go runCancelHolders(p)
    withTimeout(t.TaskBase, "cancel holders")
  block:
    let t = go runCancelWaiters(p)
    withTimeout(t.TaskBase, "cancel waiters")
  block:
    let t = go runCounter(p)
    withTimeout(t.TaskBase, "counter")
  block:
    let t = go runNotifyStress(conn, p)
    withTimeout(t.TaskBase, "notify stress")

  close(p)

var standaloneConn = run connect(connStr)
run main(standaloneConn)
close(standaloneConn)
