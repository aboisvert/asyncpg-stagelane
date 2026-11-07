#
#
#                    AsyncPG
#        (c) Copyright 2016 Eugene Kabanov
#
#    See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

## Core of the driver: connections, the single-threaded `ApgPool`, the libpq
## query pump, COPY, result access and LISTEN/NOTIFY.
##
## Concurrency model: libpq is driven in non-blocking mode. Whenever it needs the
## socket we suspend on `waitReadable`/`waitWritable` (stagelane's event loop), so
## every `{.flow.}` proc here may suspend. A connection runs one command at a time.

import db_connector/postgres, strutils, macros, json, lists, std/options
import stagelane
import apg_ffi, apg_array, apg_json, apg_oids, apg_errors, apg_params
export apg_errors, apg_params, apg_ffi

type
  ApgNotify* = object
    ## Object which represents PostgreSQL's asynchronous notify
    channel*: string
    payload*: string
    bepid: int

  NotifyWait* = ref object
    ## Handle for waiting on a LISTEN channel; register with `notify` then
    ## call `waitNotify` (from a `{.flow.}` proc) after NOTIFY is sent.
    channel*: string
    q*: WaitQueue
    arrived*: bool
    cancelled*: bool ## set by `cancel`; the registration is dropped lazily
    ntf*: ApgNotify

  ApgNotifyCell* = object
    wait*: NotifyWait ## registration from `notify`; nil for a queued server NOTIFY
    data*: ApgNotify ## full payload when `wait` is nil (pool exec path)

  ApgConnection* = ref object of RootRef
    ## Object which encapsulate connection to PostgreSQL database.
    pgconn: PPGconn
    notifies: DoublyLinkedList[ApgNotifyCell] ## `notify` registrations (and, on the
                                              ## pool exec path, queued server NOTIFYs)
    notices: seq[string]

  ApgResult* = ref object of RootRef
    ## Object which encapsulate result of executed SQL query.
    pgress: seq[PPGresult]

  ApgPool* = ref object of RootRef
    ## Object which encapsulates pool of connections to PostgreSQL database.
    ## Single-threaded: no locking (see `apg_shared_pool` for the shared variant).
    connections: seq[ApgConnection] ## a slot is nil until opened, and again after a
                                    ## broken connection was dropped
    busy: seq[bool]
    waitq: WaitQueue
    connStr: string
    notifies: DoublyLinkedList[ApgNotifyCell]

  Row* = seq[string]  ## a row of a dataset. NULL database values are
                      ## converted to "" (use `isNull` to tell them apart).

proc socketFd*(conn: PPGconn): int {.inline.} =
  result = pqsocket(conn).int

proc `=destroy`(r: typeof(ApgResult()[])) =
  ## Results are released automatically; `close` just releases them earlier.
  for p in r.pgress: pqclear(p)

proc `=destroy`(c: typeof(ApgConnection()[])) =
  ## Connections that were never `close`d are finished on collection. This must
  ## run before the object is freed because libpq keeps an unowned pointer to it
  ## (the notice receiver argument).
  if c.pgconn != nil: pqfinish(c.pgconn)

proc newPool*(size = 10): ApgPool =
  ## Creates new object ``ApgPool`` with ``size`` connections inside.

  result = ApgPool()
  result.connections = newSeq[ApgConnection](size)
  result.busy = newSeq[bool](size)
  result.waitq = newWaitQueue()
  result.notifies = initDoublyLinkedList[ApgNotifyCell]()

const MaxNotices = 64  ## oldest notices are dropped beyond this

proc noticeReceiver*(arg: pointer, res: PPGresult) {.cdecl.} =
  ## libpq callback; `arg` is the owning `ApgConnection` (not ref-counted here).
  var conn = cast[ApgConnection](arg)
  if conn.notices.len >= MaxNotices: conn.notices.delete(0)
  conn.notices.add($pqresultErrorMessage(res))

proc takeNotices*(conn: ApgConnection): seq[string] =
  ## Returns (and clears) the server notices received on `conn`.
  result = move conn.notices
  conn.notices = @[]

template pollUntilReady(conn: ApgConnection, pollCall: untyped) =
  ## Shared connect/reset polling loop.
  while true:
    let fd = socketFd(conn.pgconn)
    case pollCall
    of PGRES_POLLING_READING: waitReadable(fd)
    of PGRES_POLLING_WRITING: waitWritable(fd)
    of PGRES_POLLING_OK: break
    of PGRES_POLLING_FAILED: raiseConnError(conn.pgconn)
    else: raise newException(ApgConnectionError, "unexpected poll state")

proc connect*(connection: string): ApgConnection {.flow.} =
  ## Establish connection to PostgreSQL database using ``connection`` string.

  var conn = ApgConnection()
  conn.pgconn = pqconnectStart(connection)
  if conn.pgconn == nil:
    raise newException(ApgConnectionError, "PQconnectStart failed")
  try:
    pollUntilReady(conn, pqconnectPoll(conn.pgconn))
    # Non-blocking mode is what makes pqflush/pqputCopyData return instead of
    # stalling the event loop when the socket buffer is full.
    if pqsetnonblocking(conn.pgconn, 1) == -1:
      raiseConnError(conn.pgconn)
  except CatchableError:
    # PQconnectStart allocated a PGconn even on failure; don't leak it.
    pqfinish(conn.pgconn)
    conn.pgconn = nil
    raise
  discard pqsetErrorVerbosity(conn.pgconn, PQERRORS_VERBOSE)
  conn.notices = newSeq[string]()
  discard pqsetNoticeReceiver(conn.pgconn,
                             cast[PQnoticeReceiver](noticeReceiver),
                             cast[pointer](conn))
  conn.notifies = initDoublyLinkedList[ApgNotifyCell]()
  result = conn

proc reset*(conn: ApgConnection) {.flow.} =
  ## Resets PostgreSQL database connection ``conn``.

  if conn.pgconn == nil:
    raise newException(ApgConnectionError, "Connection is already closed")
  if pqresetStart(conn.pgconn) == 0:
    raiseConnError(conn.pgconn)
  pollUntilReady(conn, pqresetPoll(conn.pgconn))
  if pqsetnonblocking(conn.pgconn, 1) == -1:
    raiseConnError(conn.pgconn)

proc close*(conn: ApgConnection) =
  ## Closes connection to PostgreSQL server. Idempotent.

  if conn != nil and conn.pgconn != nil:
    pqfinish(conn.pgconn)
    conn.pgconn = nil

proc checkout*(pool: ApgPool): int {.flow.} =
  ## Returns the index of an idle pool connection; blocks until one is free.
  while true:
    var i = 0
    while i < pool.connections.len:
      if not pool.busy[i]:
        # Claim the slot before (possibly) suspending in `connect`, so no other
        # task can pick the same one meanwhile.
        pool.busy[i] = true
        try:
          if pool.connections[i] == nil or pool.connections[i].pgconn == nil:
            if pool.connStr.len == 0:
              raise newException(ValueError,
                "pool has no connection string; call connect(pool, ...) first")
            pool.connections[i] = connect(pool.connStr)
          return i
        except CatchableError:
          pool.busy[i] = false
          notifyOne(pool.waitq)
          raise
      inc i
    # Single-threaded: nothing can free a slot between the scan and the park, so
    # a plain `park` cannot miss a wakeup (unlike the shared pool).
    park(pool.waitq)

proc checkin*(pool: ApgPool, index: int) =
  pool.busy[index] = false
  notifyOne(pool.waitq)

proc connect*(pool: ApgPool, connection: string) {.flow.} =
  ## Establish pool's connections to PostgreSQL server using ``connection``
  ## statement. All connections are opened concurrently.

  pool.connStr = connection
  var tasks = newSeq[Task[ApgConnection]](len(pool.connections))
  for i in 0 ..< tasks.len:
    tasks[i] = go connect(connection)
  # Await every task even after a failure so none is left running against a
  # pool we are about to tear down; report the first error.
  var firstErr: ref CatchableError = nil
  for i in 0 ..< tasks.len:
    try:
      pool.connections[i] = await tasks[i]
    except CatchableError as e:
      if firstErr == nil: firstErr = e
  if firstErr != nil:
    for c in pool.connections.mitems:
      if c != nil: close(c)
    raise firstErr

proc close*(pool: ApgPool) =
  ## Closes pool's connections

  var i = 0
  while i < len(pool.connections):
    if pool.connections[i] != nil:
      close(pool.connections[i])
    inc(i)

template fillNotifyFromPg*(dst: var ApgNotify, channel: string,
                           nres: PPGNotify) =
  dst.channel = channel
  dst.payload = $(nres.extra)
  dst.bepid = nres.be_pid

proc processPendingNotifications*(conn: ApgConnection, connNotify: bool) =
  ## Drains NOTIFYs libpq has buffered. With `connNotify` they are delivered
  ## straight to waiters registered on `conn`; otherwise (pool path) they are
  ## queued on `conn` and forwarded to the pool's waiters by
  ## `forwardConnNotifiesToPool` once the exec finished.
  while true:
    var nres = pqnotifies(conn.pgconn)
    if nres == nil:
      break
    let channel = $(nres.relname)
    if connNotify:
      # Deliver the same NOTIFY to every registered waiter on this channel
      # (each waiter has its own slot). Cancelled registrations are pruned here.
      var cnode = conn.notifies.head
      while cnode != nil:
        let cnext = cnode.next
        let w = cnode.value.wait
        if w != nil and w.cancelled:
          conn.notifies.remove(cnode)
        elif w != nil and w.channel == channel:
          fillNotifyFromPg(w.ntf, channel, nres)
          w.arrived = true
          notifyOne(w.q)
          conn.notifies.remove(cnode)
        cnode = cnext
    else:
      var cell = ApgNotifyCell()
      cell.data = ApgNotify()
      fillNotifyFromPg(cell.data, channel, nres)
      conn.notifies.append(cell)
    pqfreemem(cast[pointer](nres))

proc close*(apgres: ApgResult) =
  ## Closes query results stored inside ``apgres`` (idempotent).

  for pgr in apgres.pgress:
    pqclear(pgr)
  apgres.pgress.setLen(0)

proc flushOutgoing(conn: ApgConnection, fd: int) {.flow.} =
  while true:
    let fr = pqflush(conn.pgconn)
    if fr < 0: raiseConnError(conn.pgconn)
    if fr == 0: return
    waitWritable(fd)

proc drainResults(conn: ApgConnection, notifyConn: bool,
                  res: ApgResult) {.flow.} =
  ## Pumps libpq until the current command completes (or enters COPY).
  ## After an error result it keeps draining so the connection stays usable,
  ## then raises the first error. Results gathered so far stay in `res`.
  let fd = socketFd(conn.pgconn)
  var firstErr: PPGresult = nil
  while true:
    flushOutgoing(conn, fd)
    if pqconsumeInput(conn.pgconn) == 0:
      if firstErr != nil: pqclear(firstErr)
      raiseConnError(conn.pgconn)
    processPendingNotifications(conn, notifyConn)
    while pqisBusy(conn.pgconn) == 0:
      let r = pqgetResult(conn.pgconn)
      if r == nil:
        if firstErr != nil:
          close(res)
          raiseResultError(firstErr)
        return
      case pqresultStatus(r)
      of PGRES_EMPTY_QUERY, PGRES_COMMAND_OK, PGRES_TUPLES_OK:
        res.pgress.add(r)
      of PGRES_COPY_IN, PGRES_COPY_OUT:
        # The command is now waiting for COPY data (or streaming it out); the
        # caller continues with copyTo/copyFromInto. After an error we must not
        # return early, only a nil result marks the end of the command.
        res.pgress.add(r)
        if firstErr == nil: return
      else:
        # Keep only the first error; later ones (multi-statement) are discarded.
        if firstErr == nil: firstErr = r else: pqclear(r)
    waitReadable(fd)

proc copyTo*(conn: ApgConnection, buffer: pointer,
            nbytes: int32): ApgResult {.flow.} =
  ## Copy data from buffer ``buffer`` of size ``nbytes`` to PostgreSQL's
  ## stdin.
  ## Be sure to execute ``COPY FROM`` statement before start sending data with
  ## this function. After all data have been sent, you need to finish sending
  ## process with call ``copyTo(conn, nil, 0)``.
  ## Function returns ApgResult.
  var apgres = ApgResult()
  apgres.pgress = newSeq[PPGresult]()

  let finishing = isNil(buffer) or nbytes == 0
  var putRes: int32
  while true:
    # PQputCopyData/End return 0 (not an error) when the non-blocking output
    # buffer is full; wait for the socket and retry the same call.
    if finishing:
      putRes = pqputCopyEnd(conn.pgconn, nil)
    else:
      putRes = pqputCopyData(conn.pgconn, cast[cstring](buffer), nbytes)
    if putRes < 0:
      raiseConnError(conn.pgconn)
    if putRes > 0: break
    waitWritable(socketFd(conn.pgconn))
  if finishing:
    # The server answers only after COPY END; collect that CommandComplete.
    drainResults(conn, true, apgres)
  else:
    flushOutgoing(conn, socketFd(conn.pgconn))
  result = apgres

proc copyFromInto*(conn: ApgConnection, buffer: pointer,
                   nbytes: int): int {.flow.} =
  ## Copy data caused by sql `COPY TO` statement to buffer `buffer`.
  ## Because rows received one by one, size of buffer `nbytes` must be
  ## more or equal to text representation of single row.
  ## Returns `size` of received data.
  ## Be sure to execute `COPY TO` statement, before you call this
  ## function.

  let notifyConn = true
  let fd = socketFd(conn.pgconn)
  var copyString: pointer = nil

  while true:
    # async = 1: return 0 instead of blocking when no complete row is buffered.
    let res = pqgetCopyData(conn.pgconn, cast[cstringArray](addr copyString),
                            1)
    if res > 0:
      doAssert(res.int <= nbytes)
      copyMem(cast[pointer](buffer), copyString, res)
      pqfreemem(copyString)
      return res.int
    elif res == 0:
      waitReadable(fd)
    elif res == -1:
      if copyString != nil: pqfreemem(copyString)
      processPendingNotifications(conn, notifyConn)
      while true:
        var r = pqgetResult(conn.pgconn)
        if r != nil:
          let stres = pqresultStatus(r)
          pqclear(r)
          if stres != PGRES_COMMAND_OK:
            raiseConnError(conn.pgconn)
        else:
          return 0
    else:
      if copyString != nil: pqfreemem(copyString)
      raiseConnError(conn.pgconn)

proc connectionAt*(pool: ApgPool, index: int): ApgConnection {.inline.} =
  ## The connection in slot `index` (only valid while that slot is checked out).
  pool.connections[index]

template withConnection*(poolArg: untyped, conn, body: untyped) =
  ## Retrieves first available connection from pool, assigns it
  ## to variable with name `conn`. You can use this connection
  ## inside withConnection code block. Works for `ApgPool` and `ApgSharedPool`.
  mixin checkout, checkin, connectionAt
  block:
    let apgPool = poolArg
    let apgConnIdx = checkout(apgPool)
    try:
      var conn = connectionAt(apgPool, apgConnIdx)
      body
    finally:
      checkin(apgPool, apgConnIdx)

proc pgconn*(conn: ApgConnection): PPGconn =
  ## Raw libpq handle (read-only accessor; used by `apg_shared_pool`). Do not
  ## `PQfinish` it yourself: use `close`.
  conn.pgconn

proc forwardConnNotifiesToPool*(conn: ApgConnection,
    poolNotifies: var DoublyLinkedList[ApgNotifyCell]) =
  ## Moves NOTIFYs queued on `conn` to matching waiters registered on the pool and
  ## wakes them. The caller must hold whatever lock protects `poolNotifies`.
  var cnode = conn.notifies.head
  while cnode != nil:
    let cnext = cnode.next
    let cdata = cnode.value.data
    var pnode = poolNotifies.head
    while pnode != nil:
      let pnext = pnode.next
      let w = pnode.value.wait
      if w != nil and w.cancelled:
        poolNotifies.remove(pnode)
      elif w != nil and w.channel == cdata.channel:
        w.ntf = cdata
        w.arrived = true
        notifyOne(w.q)
        poolNotifies.remove(pnode)
      pnode = pnext
    conn.notifies.remove(cnode)
    cnode = cnext

proc execAsync*(conn: ApgConnection, statement: string, pN: int32, pT: POid,
               pV: cstringArray, pL, pF: ptr int32,
               rF: int32, notifyConn = true): ApgResult {.flow.} =
  var apgres = ApgResult()
  apgres.pgress = newSeq[PPGresult]()
  var qres: int32 = 0
  if pN == 0:
    qres = pqsendQuery(conn.pgconn, statement)
  else:
    qres = pqsendQueryParams(conn.pgconn, statement, pN, pT, pV, pL, pF, rF)
  if qres == 0:
    raiseConnError(conn.pgconn)
  drainResults(conn, notifyConn, apgres)
  result = apgres

proc execPoolAsync(pool: ApgPool, statement: string, pN: int32, pT: POid,
                   pV: cstringArray, pL, pF: ptr int32,
                   rF: int32): ApgResult {.flow.} =
  let index = checkout(pool)
  try:
    result = execAsync(pool.connections[index], statement, pN, pT,
                       pV, pL, pF, rF, false)
    forwardConnNotifiesToPool(pool.connections[index], pool.notifies)
  except CatchableError as e:
    # SQL errors are drained by execAsync, so the connection is reusable unless
    # it died or is stuck in a failed/open transaction. Dropping it here (slot
    # becomes nil) makes the next `checkout` reconnect lazily.
    let c = pool.connections[index]
    if c != nil and c.pgconn != nil and
       (pqstatus(c.pgconn) != CONNECTION_OK or
        pqtransactionStatus(c.pgconn) != PQTRANS_IDLE):
      pqfinish(c.pgconn)
      c.pgconn = nil
      pool.connections[index] = nil
    raise e
  finally:
    checkin(pool, index)

# `exec` expands to a call of `execDispatch`; overloading on the first argument
# selects the implementation. Other handle types (e.g. `ApgSharedPool`) just add
# their own overload.
proc execDispatch*(conn: ApgConnection, statement: string, pN: int32, pT: POid,
                   pV: cstringArray, pL, pF: ptr int32,
                   rF: int32): ApgResult {.flow.} =
  execAsync(conn, statement, pN, pT, pV, pL, pF, rF, true)

proc execDispatch*(pool: ApgPool, statement: string, pN: int32, pT: POid,
                   pV: cstringArray, pL, pF: ptr int32,
                   rF: int32): ApgResult {.flow.} =
  execPoolAsync(pool, statement, pN, pT, pV, pL, pF, rF)

proc len*(apgres: ApgResult): int =
  ## Returns number of query results stored inside ``apgres``.

  result = len(apgres.pgress)

proc `[]`*(apgres: ApgResult, index: int): PPGresult =
  ## Returns query result from ``apgres`` by ``index``.

  result = apgres.pgress[index]

proc cellString(pgres: PPGresult, row, col: int): string {.inline.} =
  ## Cell text using the server-provided length (no strlen); NULL gives "".
  let n = pqgetlength(pgres, row.int32, col.int32)
  result = newString(n)
  if n > 0: copyMem(addr result[0], pqgetvalue(pgres, row.int32, col.int32), n)

proc isNull*(pgres: PPGresult, row = 0, col = 0): bool =
  ## True if the cell is SQL NULL (`getValue` returns "" for both NULL and "").
  pqgetisnull(pgres, row.int32, col.int32) == 1

template setRow(pgres: PPGresult, r, line, cols) =
  for col in 0..<cols:
    r[col] = cellString(pgres, line, col)

template setRowInline(pgres: PPGresult, r, line, cols) =
  for col in 0..<cols:
    let n = pqgetlength(pgres, line.int32, col.int32)
    r[col].setLen(n)
    if n > 0:
      copyMem(addr r[col][0], pqgetvalue(pgres, line.int32, col.int32), n)

proc getValue*(pgres: PPGresult): string =
  ## Returns single value from result ``pgres``.

  result = cellString(pgres, 0, 0)

proc getValueOpt*(pgres: PPGresult, row = 0, col = 0): Option[string] =
  ## `none` for SQL NULL, otherwise the cell text.
  if isNull(pgres, row, col): none(string)
  else: some(cellString(pgres, row, col))


proc getRow*(pgres: PPGresult): Row =
  ## Returns ``Row`` value from result ``pgres``. The result stays owned by
  ## its ``ApgResult`` (release it with ``close``).

  var L = pqnfields(pgres)
  result = newSeq[string](L)
  setRow(pgres, result, 0, L)

proc getRows*(pgres: PPGresult, rows: int): seq[Row] =
  ## Returns at least ``row`` number of rows from result ``pgres``.
  ## If ``row`` is -1, all rows will be returned.

  var L = pqnfields(pgres)
  var R = pqntuples(pgres).int
  if (rows != -1) and (rows < R):
    R = rows
  result = newSeq[Row](R)
  for row in 0..<R:
    result[row] = newSeq[string](L)
    setRow(pgres, result[row], row, L)

template getAllRows*(pgres: PPGresult): seq[Row] =
  ## Returns all rows from result ``pgres``.

  getRows(pgres, -1)

iterator rows*(pgres: PPGresult): Row =
  ## Iterates over ``pgres`` result rows

  # One buffer is reused for every row to avoid per-row allocations, so the
  # yielded row is only valid until the next iteration; copy it to keep it.
  var L = pqnfields(pgres)
  var R = pqntuples(pgres)
  var result = newSeq[string](L)
  for i in 0..<L:
    result[i] = ""
  for i in 0..<R:
    setRowInline(pgres, result, i, L)
    yield result

proc getAffectedRows*(pgres: PPGresult): int64 =
  ## Returns number of affected rows for ``pgres`` result.

  let t = $pqcmdTuples(pgres)
  result = if t.len == 0: 0'i64 else: parseBiggestInt(t)

proc setClientEncoding*(conn: ApgConnection,
                        encoding: string) {.flow.} =
  ## Sets the client encoding.

  # `SET` cannot take bind parameters, so the name is spliced into the SQL and
  # must be validated instead.
  for ch in encoding:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      raise newException(ValueError, "invalid encoding name: " & encoding)
  var ares = execAsync(conn, "set client_encoding to '" & encoding & "'",
                       0, nil, nil, nil, nil, 0)
  close(ares)

proc getClientEncoding*(conn: ApgConnection): string =
  ## Returns the client encoding.

  result = $pgEncodingToChar(pqclientEncoding(conn.pgconn))

proc getVersion*(): int =
  ## Returns an integer representing the libpq version.

  result = pqlibVersion().int

proc getServerVersion*(conn: ApgConnection): int =
  ## Returns an integer representing the backend version.

  result = pqserverVersion(conn.pgconn).int

proc getProtocolVersion*(conn: ApgConnection): int =
  ## Interrogates the frontend/backend protocol being used.

  result = pqprotocolVersion(conn.pgconn).int

macro exec*(conn: typed, statement: string,
            params: varargs[typed]): ApgResult =
  ## Submits a command ``statement`` to the server connection
  ## or connection's pool. ``params`` is SQL parameters which will
  ## be passed with command.
  result = newCall(bindSym"apgExecImpl", newLit"execDispatch", conn, statement)
  for p in params:
    result.add(p)

#
# Asynchronous notify
#

proc expectStatus*(res: ApgResult, want: ExecStatusType) =
  ## Closes `res` and raises `ApgQueryError` unless its first result has status
  ## `want`. The message is read first because `close` frees the PGresult.
  let st = pqresultStatus(res.pgress[0])
  let msg = $pqresultErrorMessage(res.pgress[0])
  close(res)
  if st != want:
    raise newException(ApgQueryError, msg)

template checkResultCommand*(res) = expectStatus(res, PGRES_COMMAND_OK)
template checkResultTuple*(res) = expectStatus(res, PGRES_TUPLES_OK)

template defineNotifyOps*(T: typedesc) =
  ## Defines `listenNotify`, `unlistenNotify` and `sendNotify` for a handle type
  ## that `exec` accepts (connection or pool).
  proc listenNotify*(c: T, channel: string) {.flow.} =
    ## Registers listening for asynchronous notifies on `channel`.
    var query = "LISTEN " & quoteIdent(channel)
    var res = exec(c, query)
    checkResultCommand(res)

  proc unlistenNotify*(c: T, channel: string) {.flow.} =
    ## Unregisters listening for asynchronous notifies on `channel`.
    var query = "UNLISTEN " & quoteIdent(channel)
    var res = exec(c, query)
    checkResultCommand(res)

  proc sendNotify*(c: T, channel: string, payload: string) {.flow.} =
    ## Send asynchronous notify to `channel` with data in `payload`
    ## (must be shorter than 8000 bytes).
    doAssert(len(payload) < 8000) # PostgreSQL limit for NOTIFY payloads
    var p1 = channel
    var p2 = payload
    var query = "SELECT pg_notify($1, $2);"
    var res = exec(c, query, p1, p2)
    checkResultTuple(res)

defineNotifyOps(ApgConnection)
defineNotifyOps(ApgPool)

proc notify*(conn: ApgConnection|ApgPool, channel: string): NotifyWait =
  ## Register to wait for NOTIFY on ``channel``. Call `waitNotify` from a
  ## `{.flow.}` context after NOTIFY is sent. Register *before* sending: only
  ## NOTIFYs arriving after registration are delivered. The channel must also
  ## have been `listenNotify`'d on the connection that will run the next exec.

  var cell = ApgNotifyCell()
  var w = NotifyWait()
  w.channel = channel
  w.q = newWaitQueue()
  w.arrived = false
  cell.wait = w
  conn.notifies.append(cell)
  return w

proc cancel*(w: NotifyWait) =
  ## Drops the registration so a later NOTIFY is not consumed by a waiter that
  ## has given up (timeout, cancelled task). Idempotent.
  w.cancelled = true

proc waitNotify*(w: NotifyWait): ApgNotify {.flow.} =
  ## Block until the NOTIFY registered by `notify` arrives. If the waiting task
  ## is cancelled or times out, the registration is dropped.
  try:
    while not w.arrived:
      # Snapshot the epoch before re-checking `arrived`: a notify from another
      # thread between the check and the park bumps it, so `parkSince` returns
      # immediately.
      let e = epochOf(w.q)
      if not w.arrived:
        parkSince(w.q, e)
  finally:
    # Reached without a NOTIFY only on cancellation/timeout: unregister so the
    # next NOTIFY is not swallowed by a waiter nobody is listening to.
    if not w.arrived: w.cancelled = true
  return w.ntf

