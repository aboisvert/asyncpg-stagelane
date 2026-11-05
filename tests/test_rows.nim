import asyncdispatch, asyncpg_stagelane, test_db

proc testRows(conn: apgConnection) {.async.} =
  block: # multiple statements in one query test
    var res = await asyncpg_stagelane.exec(conn, "SELECT 3;SELECT 4;SELECT 5;")
    var length = len(res)
    doAssert(length == 3)
    var value1 = getValue(res[0])
    var value2 = getValue(res[1])
    var value3 = getValue(res[2])
    doAssert(value1 == "3" and value2 == "4" and value3 == "5")
    close(res)

  block: # issue #1
    var res = await asyncpg_stagelane.exec(conn, "SELECT unnest(ARRAY['1', '2', '3']);")
    var value = ""
    for item in res[0].rows():
      value = value & item[0]
    doAssert(value == "123")

var conn = waitFor connect(connStr)
waitFor testRows(conn)
close(conn)