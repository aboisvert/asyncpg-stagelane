import stagelane, asyncpg_stagelane, test_db

const POOL_SIZE = 20

proc makeLongCall(pool: ApgPool) {.flow.} =
  var res = exec(pool, "SELECT pg_sleep(1);")
  close(res)

proc makeShortCall(pool: ApgPool) {.flow.} =
  var res = exec(pool, "SELECT pg_sleep(0.5);")
  close(res)

proc testPool(pool: ApgPool): bool {.flow.} =
  result = false
  var i = 0
  var tasks = newSeq[Task[void]](POOL_SIZE)
  while i < POOL_SIZE:
    tasks[i] = go makeLongCall(pool)
    inc(i)
  # `go` only queues the tasks. Yield so each long call checks out a
  # connection and starts pg_sleep before this task asks for one.
  yieldNow()
  makeShortCall(pool)
  var k = 0
  i = 0
  while i < POOL_SIZE:
    if done(tasks[i].TaskBase):
      inc(k)
    inc(i)
  if k == POOL_SIZE:
    result = true

proc testWithConnection(apgP: ApgPool): bool {.flow.} =
  result = true

  withConnection(apgP, conn) do:
    setClientEncoding(conn, "WIN1252")
  withConnection(apgP, conn) do:
    var b = getClientEncoding(conn)
    if b != "WIN1252":
      result = false

var pool = newPool(POOL_SIZE)

run pool.connect(connStr)
block:
  var res = run testPool(pool)
  doAssert(res)

block:
  var res = run testWithConnection(pool)
  doAssert(res)

close(pool)
