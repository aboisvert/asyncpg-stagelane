## Thread-safe connection pool for multi-threaded stagelane (`-d:flowThreads`).
##
## Import this module (not re-exported from `asyncpg_stagelane`) when sharing one pool
## across OS threads. Build with `--threads:on --mm:atomicArc -d:flowThreads`.
##
## Design notes:
## * Each `PGconn` still has exactly one borrower at a time (checkout/checkin), which is
##   all libpq requires. Socket waits are registered on the *borrowing* thread's
##   scheduler and are gone by the time the operation finishes, so the next borrower may
##   be on a different thread.
## * `pool.lock` only guards the pool's bookkeeping and is never held across a
##   suspension point (connect / exec / park).
## * Wakeups across threads rely on stagelane's `flowThreads` mode, which posts a woken
##   task back to the scheduler of the thread that owns it.

when not defined(flowThreads):
  {.error: "apg_shared_pool needs -d:flowThreads --threads:on --mm:atomicArc".}

import std/[locks, lists, macros]
import db_connector/postgres
import stagelane
import apg_core

type
  SlotState = enum
    ssEmpty      ## no connection in this slot (never opened, or discarded)
    ssIdle       ## open connection, available for checkout
    ssBusy       ## checked out by a task
    ssConnecting ## reserved by a task that is opening the connection (lock not held)

  ApgSharedPoolClosedError* = object of CatchableError
    ## Raised by `checkout`/`connect` once the pool has been closed.

  ApgSharedPool* = ref object of RootRef
    ## Connection pool that may be shared by tasks on several OS threads.
    lock: Lock                 ## guards every field below
    connections*: seq[ApgConnection] ## slot storage; only touch the slot you checked out
    state: seq[SlotState]      ## per-slot state, parallel to `connections`
    waitq: WaitQueue           ## tasks waiting for a free slot (see `checkout`)
    connStr: string
    notifies: DoublyLinkedList[ApgNotifyCell] ## pending `notify` registrations
    closed: bool               ## set by `close`; new checkouts fail
    lockReleased: bool         ## `lock` was deinitialised; the pool is unusable

template withPoolLock(pool: ApgSharedPool, body: untyped) =
  ## Run `body` holding `pool.lock`. Never suspend (park/await/connect/exec) inside it.
  acquire(pool.lock)
  try:
    body
  finally:
    release(pool.lock)

proc connectionHealthy(conn: ApgConnection): bool =
  conn != nil and pgconn(conn) != nil and pqstatus(pgconn(conn)) == CONNECTION_OK

proc shouldDiscardConn(conn: ApgConnection): bool =
  ## A returned connection is only safe to hand to the next borrower when it is healthy
  ## and idle at the SQL level. An open transaction (or failed one) would leak state to
  ## whichever thread borrows it next, so such connections are dropped instead.
  if not connectionHealthy(conn):
    result = true
  else:
    result = pqtransactionStatus(pgconn(conn)) != PQTRANS_IDLE

proc discardConn(conn: var ApgConnection) =
  if conn != nil and pgconn(conn) != nil:
    close(conn)
  conn = nil

proc newSharedPool*(size = 10): ApgSharedPool =
  ## Creates a pool with `size` slots. Connections are opened by `connect` or lazily
  ## by `checkout` (for slots emptied by `checkin`).
  if pqisthreadsafe() == 0:
    raise newException(ValueError, "libpq was not built thread-safe")
  result = ApgSharedPool()
  result.connections = newSeq[ApgConnection](size)
  result.state = newSeq[SlotState](size)
  for i in 0 ..< size:
    result.state[i] = ssEmpty
  initLock(result.lock)
  result.waitq = newWaitQueue()
  result.notifies = initDoublyLinkedList[ApgNotifyCell]()

proc connect*(pool: ApgSharedPool, connection: string) {.flow.} =
  ## Opens every slot's connection. The lock is only taken to publish each connection,
  ## not while connecting.
  pool.connStr = connection
  var i = 0
  while i < pool.connections.len:
    let c = apg_core.connect(connection)
    withPoolLock pool:
      if pool.closed:
        close(c)
        raise newException(ApgSharedPoolClosedError, "pool is closed")
      pool.connections[i] = c
      pool.state[i] = ssIdle
    inc i

proc checkout*(pool: ApgSharedPool): int {.flow.} =
  ## Returns the index of a connection reserved for the caller; suspends until a slot
  ## is free. Pair with `checkin` (prefer `withConnection`).
  while true:
    # Read the epoch *before* scanning: if a checkin bumps it between our scan and
    # `parkSince`, the park returns immediately instead of losing the wakeup.
    let e = epochOf(pool.waitq)
    var idleIdx = -1
    var connectIdx = -1
    var connStr = ""
    withPoolLock pool:
      if pool.closed:
        raise newException(ApgSharedPoolClosedError, "pool is closed")
      var i = 0
      while i < pool.connections.len:
        if pool.state[i] == ssIdle:
          pool.state[i] = ssBusy
          idleIdx = i
          break
        inc i
      if idleIdx < 0:
        # No idle connection: reserve an empty slot so we can open one outside the lock.
        i = 0
        while i < pool.connections.len:
          if pool.state[i] == ssEmpty:
            if pool.connStr.len == 0:
              raise newException(ValueError,
                "pool has no connection string; call connect(pool, ...) first")
            pool.state[i] = ssConnecting
            connectIdx = i
            connStr = pool.connStr
            break
          inc i
    # `return` is kept outside the lock block so the lock is always released first.
    if idleIdx >= 0:
      return idleIdx
    if connectIdx >= 0:
      try:
        let c = apg_core.connect(connStr)
        var readyIdx = -1
        withPoolLock pool:
          if pool.closed:
            close(c)
            pool.state[connectIdx] = ssEmpty
            raise newException(ApgSharedPoolClosedError, "pool is closed")
          pool.connections[connectIdx] = c
          pool.state[connectIdx] = ssBusy
          readyIdx = connectIdx
        return readyIdx
      except CatchableError:
        # Give the slot back and let another waiter try.
        withPoolLock pool:
          pool.state[connectIdx] = ssEmpty
        notifyOne(pool.waitq)
        raise
    try:
      parkSince(pool.waitq, e)
    except CancelledError:
      # Pass on a wakeup we may have consumed so the next waiter is not stranded.
      notifyOne(pool.waitq)
      raise

proc checkin*(pool: ApgSharedPool, index: int) =
  ## Returns slot `index` to the pool and wakes one waiter. Dirty or broken connections,
  ## and every connection once the pool is closed, are discarded rather than reused.
  withPoolLock pool:
    var conn = pool.connections[index]
    if pool.closed or shouldDiscardConn(conn):
      discardConn(conn)
      pool.connections[index] = nil
      pool.state[index] = ssEmpty
    else:
      pool.state[index] = ssIdle
  notifyOne(pool.waitq)

proc releasePoolLock(pool: ApgSharedPool) =
  if not pool.lockReleased:
    deinitLock(pool.lock)
    pool.lockReleased = true

proc close*(pool: ApgSharedPool) =
  ## Graceful close: marks the pool closed, closes idle connections now, wakes waiting
  ## checkouts (they raise `ApgSharedPoolClosedError`). Busy connections are closed by
  ## their `checkin`.
  if pool.lockReleased:
    return
  var toClose: seq[ApgConnection] = @[]
  withPoolLock pool:
    if pool.closed:
      discard
    else:
      pool.closed = true
    for i in 0 ..< pool.connections.len:
      if pool.state[i] == ssIdle and pool.connections[i] != nil:
        toClose.add(pool.connections[i])
        pool.connections[i] = nil
        pool.state[i] = ssEmpty
  # Close sockets and wake waiters outside the lock.
  if pool.closed:
    for c in toClose:
      close(c)
    notifyAll(pool.waitq)
  releasePoolLock(pool)

template withConnection*(poolArg: ApgSharedPool, conn, body: untyped) =
  ## Checks out a connection into `conn` for the duration of `body`. The connection must
  ## not escape the block.
  mixin checkout, checkin
  block:
    let apgConnIdx = checkout(poolArg)
    try:
      var conn = poolArg.connections[apgConnIdx]
      body
    finally:
      checkin(poolArg, apgConnIdx)

proc execSharedPoolAsync*(pool: ApgSharedPool, statement: string, pN: int32,
                         pT: POid, pV: cstringArray, pL, pF: ptr int32,
                         rF: int32): ApgResult {.flow.} =
  ## Runs one statement on a checked-out connection (target of the `exec` macro).
  let index = checkout(pool)
  try:
    # `notifyConn = false`: NOTIFYs are queued on the connection, then forwarded to
    # the pool's waiters below.
    result = execAsync(pool.connections[index], statement, pN, pT,
                       pV, pL, pF, rF, false)
    withPoolLock pool:
      forwardConnNotifiesToPool(pool.connections[index], pool.notifies)
  except CatchableError as e:
    # The connection state is unknown after a failure: drop it.
    if pool.connections[index] != nil and pgconn(pool.connections[index]) != nil:
      close(pool.connections[index])
      pool.connections[index] = nil
      withPoolLock pool:
        pool.state[index] = ssEmpty
    raise e
  finally:
    checkin(pool, index)

# `exec` is redefined here (rather than reusing apg_core's) so the pool type dispatches
# to `execSharedPoolAsync`; parameter binding is shared via `apgExecImpl`.
macro exec*(conn: ApgSharedPool, statement: string,
            params: varargs[typed]): ApgResult =
  ## Same parameter binding as ``apg_core.exec``, dispatched to ``execSharedPoolAsync``.
  result = newCall(bindSym"apgExecImpl", newLit"execSharedPoolAsync", conn, statement)
  for p in params:
    result.add(p)

# Re-declared for `ApgConnection` so importing this module does not hide the plain
# connection overload of `exec`.
macro exec*(conn: ApgConnection, statement: string,
            params: varargs[typed]): ApgResult =
  result = newCall(bindSym"apgExecImpl", newLit"execDispatch", conn, statement)
  for p in params:
    result.add(p)

template checkResultCommand(res) =
  var sres = pqresultStatus(res[0])
  close(res)
  if sres != PGRES_COMMAND_OK:
    raise newException(ValueError, $pqerrorMessage(res[0].conn))

template checkResultTuple(res) =
  var sres = pqresultStatus(res[0])
  close(res)
  if sres != PGRES_TUPLES_OK:
    raise newException(ValueError, $pqerrorMessage(res[0].conn))

proc listenNotify*(pool: ApgSharedPool, channel: string) {.flow.} =
  ## Issues `LISTEN` on the single connection checked out for this call.
  var query = "LISTEN \"" & channel & "\";"
  var res = exec(pool, query)
  checkResultCommand(res)

proc unlistenNotify*(pool: ApgSharedPool, channel: string) {.flow.} =
  var query = "UNLISTEN \"" & channel & "\";"
  var res = exec(pool, query)
  checkResultCommand(res)

proc sendNotify*(pool: ApgSharedPool, channel: string,
                 payload: string) {.flow.} =
  doAssert(len(payload) < 8000)
  var p1 = channel
  var p2 = payload
  var query = "SELECT pg_notify($1, $2);"
  var res = exec(pool, query, p1, p2)
  checkResultTuple(res)

proc notify*(pool: ApgSharedPool, channel: string): NotifyWait =
  ## Registers a waiter for `channel`; call `waitNotify` on the result. The registration
  ## is lock-protected because any thread's exec may deliver the NOTIFY.
  var cell = ApgNotifyCell()
  var w = NotifyWait()
  w.channel = channel
  w.q = newWaitQueue()
  w.arrived = false
  cell.wait = w
  withPoolLock pool:
    pool.notifies.append(cell)
  w

export apg_core except exec
export close, ApgSharedPool, newSharedPool, connect, checkout, checkin,
  withConnection, listenNotify, unlistenNotify, sendNotify, notify, exec,
  ApgSharedPoolClosedError
