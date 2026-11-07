import stagelane, asyncpg_stagelane, test_db
import torture_lib

proc main(conn: ApgConnection) {.flow.} =
  let knobs = defaultTortureKnobs()
  let p = newPool(knobs.poolSize)
  connect(p, connStr)
  runTortureSuite(conn, p, knobs)
  close(p)

var standaloneConn = run connect(connStr)
run main(standaloneConn)
close(standaloneConn)
