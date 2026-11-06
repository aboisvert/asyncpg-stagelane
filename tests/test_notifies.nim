import stagelane, asyncpg_stagelane, test_db

proc testConnectionNotify(conn: apgConnection): bool {.flow.} =
  var r1 = false
  var r2 = false
  conn.listenNotify("testChannel")
  var wait1 = conn.notify("testChannel")
  conn.sendNotify("testChannel", "payload")
  if waitFor(go waitNotify(wait1), 100):
    r1 = true
  conn.unlistenNotify("testChannel")
  var wait2 = conn.notify("testChannel")
  conn.sendNotify("testChannel", "payload")
  if not waitFor(go waitNotify(wait2), 100):
    r2 = true
  result = r1 and r2

proc testPoolNotify(pool: apgPool): bool {.flow.} =
  var r1 = false
  var r2 = false
  pool.listenNotify("testChannel")
  var waitN = pool.notify("testChannel")
  pool.sendNotify("testChannel", "payload")
  if waitFor(go waitNotify(waitN), 100):
    r1 = true
  else:
    r1 = false
  pool.unlistenNotify("testChannel")
  var wait2 = pool.notify("testChannel")
  pool.sendNotify("testChannel", "payload")
  if not waitFor(go waitNotify(wait2), 100):
    r2 = true
  result = r1 and r2

var conn = run connect(connStr)
var pool = newPool(10)
run pool.connect(connStr)

block: # asynchronous notify on connection test
  var r = run testConnectionNotify(conn)
  doAssert(r)

block: # asynchronous notify on pool test
  var r = run testPoolNotify(pool)
  doAssert(r)

close(pool)
close(conn)
