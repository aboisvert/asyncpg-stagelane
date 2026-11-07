## Regression tests for bugs fixed in the review/refactor.
import std/[json, strutils]
import stagelane, asyncpg_stagelane, test_db

proc q1(conn: ApgConnection, sql: string): string {.flow.} =
  var res = exec(conn, sql)
  result = getValue(res[0])
  close(res)

proc testGetRowNoDoubleFree(conn: ApgConnection) {.flow.} =
  var res = exec(conn, "SELECT 1, 'a'")
  let r = getRow(res[0])
  doAssert r == @["1", "a"]
  close(res)  # used to double-free the PGresult
  close(res)  # idempotent

proc testErrorThenReuse(conn: ApgConnection) {.flow.} =
  var raised = false
  try:
    var res = exec(conn, "SELECT 1/0")
    close(res)
  except ApgQueryError as e:
    raised = true
    doAssert e.sqlState == "22012", e.sqlState
  doAssert raised
  # Connection must still be usable (results were drained).
  doAssert q1(conn, "SELECT 42") == "42"

proc testMultiStatementError(conn: ApgConnection) {.flow.} =
  var raised = false
  try:
    var res = exec(conn, "SELECT 1; SELECT 1/0; SELECT 2")
    close(res)
  except ApgQueryError:
    raised = true
  doAssert raised
  doAssert q1(conn, "SELECT 7") == "7"

proc testListenError(conn: ApgConnection) {.flow.} =
  # Channel names are quoted, so odd names work and cannot inject SQL.
  listenNotify(conn, "we\"ird; DROP TABLE x; --")
  unlistenNotify(conn, "we\"ird; DROP TABLE x; --")
  # A failed command now reports the SQL error, not an IndexDefect.
  var raised = false
  try:
    var res = exec(conn, "SELEC 1")
    close(res)
  except ApgQueryError as e:
    raised = true
    doAssert e.sqlState == "42601"
  doAssert raised

proc testParams(conn: ApgConnection) {.flow.} =
  block: # empty string
    var res = exec(conn, "SELECT length($1::text)", "")
    doAssert getValue(res[0]) == "0"
    close(res)
  block: # expression strings (not lvalues)
    let a = "ab"
    var res = exec(conn, "SELECT $1::text", a & "cd")
    doAssert getValue(res[0]) == "abcd"
    close(res)
  block: # empty bytea
    var e: seq[uint8]
    var res = exec(conn, "SELECT length($1::bytea)", e)
    doAssert getValue(res[0]) == "0"
    close(res)
  block: # Json / JsonB held in variables
    var j = Json(%*{"a": 1})
    var jb = JsonB(%*{"b": 2})
    var res = exec(conn, "SELECT $1::json->>'a', $2::jsonb->>'b'", j, jb)
    doAssert getValue(res[0]) == "1"
    close(res)

proc testNull(conn: ApgConnection) {.flow.} =
  var res = exec(conn, "SELECT NULL::text, ''::text")
  doAssert isNull(res[0], 0, 0)
  doAssert not isNull(res[0], 0, 1)
  doAssert getValueOpt(res[0], 0, 0).isNone
  doAssert getValueOpt(res[0], 0, 1).get == ""
  close(res)

proc testAffected(conn: ApgConnection) {.flow.} =
  var res = exec(conn, "SELECT 1")
  doAssert getAffectedRows(res[0]) == 1 or getAffectedRows(res[0]) == 0
  close(res)

proc testPoolSurvivesErrors(pool: ApgPool) {.flow.} =
  # After SQL errors the pool keeps its connections (no reconnect per error).
  var pid0 = ""
  block:
    var res = exec(pool, "SELECT pg_backend_pid()")
    pid0 = getValue(res[0])
    close(res)
  for i in 0 ..< 5:
    try:
      var res = exec(pool, "SELECT 1/0")
      close(res)
    except ApgQueryError:
      discard
  var res = exec(pool, "SELECT pg_backend_pid()")
  doAssert getValue(res[0]) == pid0, "connection was replaced after SQL error"
  close(res)

proc testNotices(conn: ApgConnection) {.flow.} =
  var res = exec(conn, "DO $$ BEGIN RAISE NOTICE 'hi'; END $$")
  close(res)
  let n = takeNotices(conn)
  doAssert n.len >= 1 and "hi" in n[0]
  doAssert takeNotices(conn).len == 0

proc testCancelledWaiter(conn: ApgConnection) {.flow.} =
  # A timed-out waiter must not consume the next NOTIFY.
  listenNotify(conn, "reg_cancel")
  var w1 = conn.notify("reg_cancel")
  discard waitFor(go waitNotify(w1), 20)   # nothing sent: times out
  doAssert w1.cancelled or not w1.arrived
  cancel(w1)
  var w2 = conn.notify("reg_cancel")
  sendNotify(conn, "reg_cancel", "p")
  doAssert waitFor(go waitNotify(w2), 200)
  doAssert not w1.arrived
  unlistenNotify(conn, "reg_cancel")

proc testIdempotentClose() {.flow.} =
  var c = connect(connStr)
  close(c)
  close(c)  # no longer raises

var conn = run connect(connStr)
run testCancelledWaiter(conn)
run testIdempotentClose()
run testGetRowNoDoubleFree(conn)
run testErrorThenReuse(conn)
run testMultiStatementError(conn)
run testListenError(conn)
run testParams(conn)
run testNull(conn)
run testAffected(conn)
run testNotices(conn)
close(conn)

var pool = newPool(1)
run pool.connect(connStr)
run testPoolSurvivesErrors(pool)
close(pool)
echo "regressions ok"
