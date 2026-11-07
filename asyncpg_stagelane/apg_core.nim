#
#
#                    AsyncPG
#        (c) Copyright 2016 Eugene Kabanov
#
#    See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

## This is core module

import db_connector/postgres, strutils, macros, json, lists
import stagelane
import apg_array, apg_json, byteswap

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
    ntf*: ApgNotify

  ApgNotifyCell* = object
    wait*: NotifyWait ## registration from `notify`; nil for a queued server NOTIFY
    data*: ApgNotify ## full payload when `wait` is nil (pool exec path)

  ApgConnection* = ref object of RootRef
    ## Object which encapsulate connection to PostgreSQL database.
    pgconn: PPGconn
    notifies: DoublyLinkedList[ApgNotifyCell]
    notices: seq[string]

  ApgResult* = ref object of RootRef
    ## Object which encapsulate result of executed SQL query.
    pgress: seq[PPGresult]

  ApgPool* = ref object of RootRef
    ## Object which encapsulates pool of connections to PostgreSQL database.
    connections*: seq[ApgConnection]
    busy: seq[bool]
    waitq: WaitQueue
    connStr: string
    notifies: DoublyLinkedList[ApgNotifyCell]

  Row* = seq[string]  ## a row of a dataset. NULL database values will be
                      ## converted to nil.

when defined(windows):
  const dllName = "libpq.dll"
elif defined(macosx):
  # Homebrew's libpq is keg-only. Point dyld at it before launch, for example:
  #   export DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix libpq)/lib"
  const dllName = "libpq.dylib"
else:
  const dllName = "libpq.so(.5|)"

proc pgEncodingToChar(encoding: int32): cstring
     {.cdecl, dynlib: dllName, importc: "pg_encoding_to_char"}
proc pqlibVersion(): cint
     {.cdecl, dynlib: dllName, importc: "PQlibVersion".}
proc pqserverVersion(conn: PPGconn): cint
     {.cdecl, dynlib: dllname, importc: "PQserverVersion".}
proc pqisthreadsafe*(): cint
     {.cdecl, dynlib: dllName, importc: "PQisthreadsafe".}

proc socketFd*(conn: PPGconn): int {.inline.} =
  result = pqsocket(conn).int

proc newPool*(size = 10): ApgPool =
  ## Creates new object ``ApgPool`` with ``size`` connections inside.

  result = ApgPool()
  result.connections = newSeq[ApgConnection](size)
  result.busy = newSeq[bool](size)
  result.waitq = newWaitQueue()
  result.notifies = initDoublyLinkedList[ApgNotifyCell]()

proc noticeReceiver*(arg: pointer, res: PPGresult) {.cdecl.} =
  var conn = cast[ApgConnection](arg)
  conn.notices.add($pqresultErrorMessage(res))

proc connect*(connection: string): ApgConnection {.flow.} =
  ## Establish connection to PostgreSQL database using ``connection`` string.

  var conn = ApgConnection()
  conn.pgconn = pqconnectStart(connection)
  if conn.pgconn == nil:
    raise newException(ValueError, "PQconnectStart failed")

  while true:
    let fd = socketFd(conn.pgconn)
    case pqconnectPoll(conn.pgconn)
    of PGRES_POLLING_READING:
      waitReadable(fd)
    of PGRES_POLLING_WRITING:
      waitWritable(fd)
    of PGRES_POLLING_FAILED:
      raise newException(ValueError, $pqerrorMessage(conn.pgconn))
    of PGRES_POLLING_OK:
      break
    else:
      raise newException(ValueError, "Unsupported pqconnectPoll() result")

  if pqsetnonblocking(conn.pgconn, 1) == -1:
    raise newException(ValueError, $pqerrorMessage(conn.pgconn))
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
    raise newException(ValueError, "Connection is already closed")

  if pqresetStart(conn.pgconn) == 0:
    raise newException(ValueError, $pqerrorMessage(conn.pgconn))

  while true:
    let fd = socketFd(conn.pgconn)
    case pqresetPoll(conn.pgconn)
    of PGRES_POLLING_READING:
      waitReadable(fd)
    of PGRES_POLLING_WRITING:
      waitWritable(fd)
    of PGRES_POLLING_FAILED:
      raise newException(ValueError, $pqerrorMessage(conn.pgconn))
    of PGRES_POLLING_OK:
      if pqsetnonblocking(conn.pgconn, 1) == -1:
        raise newException(ValueError, $pqerrorMessage(conn.pgconn))
      return
    else:
      raise newException(ValueError, "Unsupported pqresetPoll() result")


proc close*(conn: ApgConnection) =
  ## Closes connection to PostgreSQL server

  if conn.pgconn != nil:
    pqfinish(conn.pgconn)
    conn.pgconn = nil
  else:
    raise newException(ValueError, "Connection is already closed")

proc checkout*(pool: ApgPool): int {.flow.} =
  ## Returns the index of an idle pool connection; blocks until one is free.
  while true:
    var i = 0
    while i < pool.connections.len:
      if not pool.busy[i]:
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
    park(pool.waitq)

proc checkin*(pool: ApgPool, index: int) =
  pool.busy[index] = false
  notifyOne(pool.waitq)

proc connect*(pool: ApgPool, connection: string) {.flow.} =
  ## Establish pool's connections to PostgreSQL server using ``connection``
  ## statement.

  pool.connStr = connection
  var i = 0
  while i < len(pool.connections):
    pool.connections[i] = connect(connection)
    inc(i)

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
  while true:
    var nres = pqnotifies(conn.pgconn)
    if nres == nil:
      break
    let channel = $(nres.relname)
    if connNotify:
      ## Deliver the same NOTIFY to every registered waiter on this channel
      ## (each waiter has its own slot).
      var cnode = conn.notifies.head
      while cnode != nil:
        let cnext = cnode.next
        let w = cnode.value.wait
        if w != nil and w.channel == channel:
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
  let notifyConn = true
  let fd = socketFd(conn.pgconn)

  var putRes: int32
  if isNil(buffer) or nbytes == 0:
    putRes = pqputCopyEnd(conn.pgconn, nil)
  else:
    putRes = pqputCopyData(conn.pgconn, cast[cstring](buffer), nbytes)

  if putRes < 0:
    raise newException(ValueError, $pqerrorMessage(conn.pgconn))

  if putRes == 1:
    processPendingNotifications(conn, notifyConn)
    while true:
      var r = pqgetResult(conn.pgconn)
      if r != nil:
        let stres = pqresultStatus(r)
        case stres
        of PGRES_EMPTY_QUERY, PGRES_COMMAND_OK, PGRES_TUPLES_OK:
          apgres.pgress.add(r)
        of PGRES_COPY_IN:
          apgres.pgress.add(r)
          return apgres
        else:
          raise newException(ValueError, $pqerrorMessage(conn.pgconn))
      else:
        return apgres

  while true:
    while true:
      let fr = pqflush(conn.pgconn)
      if fr < 0:
        raise newException(ValueError, $pqerrorMessage(conn.pgconn))
      if fr == 0:
        break
      waitWritable(fd)
    var copyDone = false
    if pqconsumeInput(conn.pgconn) == 0:
      raise newException(ValueError, $pqerrorMessage(conn.pgconn))
    processPendingNotifications(conn, notifyConn)
    while pqisBusy(conn.pgconn) == 0:
      var r = pqgetResult(conn.pgconn)
      if r != nil:
        let stres = pqresultStatus(r)
        case stres
        of PGRES_EMPTY_QUERY, PGRES_COMMAND_OK, PGRES_TUPLES_OK:
          apgres.pgress.add(r)
        of PGRES_COPY_IN, PGRES_COPY_OUT:
          apgres.pgress.add(r)
          copyDone = true
          break
        else:
          raise newException(ValueError, $pqerrorMessage(conn.pgconn))
      else:
        copyDone = true
        break
    if copyDone:
      return apgres
    waitReadable(fd)

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
            raise newException(ValueError, $pqerrorMessage(conn.pgconn))
        else:
          return 0
    else:
      if copyString != nil: pqfreemem(copyString)
      raise newException(ValueError, $pqerrorMessage(conn.pgconn))

template withConnection*(poolArg: ApgPool, conn, body: untyped) =
  ## Retrieves first available connection from pool, assign it
  ## to variable with name `conn`. You can use this connection
  ## inside withConnection code block.
  mixin checkout, checkin
  block:
    let apgConnIdx = checkout(poolArg)
    try:
      var conn = poolArg.connections[apgConnIdx]
      body
    finally:
      checkin(poolArg, apgConnIdx)

proc pgconn*(conn: ApgConnection): PPGconn =
  ## Raw libpq handle (read-only accessor; used by `apg_shared_pool`).
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
      if w != nil and w.channel == cdata.channel:
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
  let fd = socketFd(conn.pgconn)
  var query: cstring = statement
  var qres: int32 = 0
  if pN == 0:
    qres = pqsendQuery(conn.pgconn, query)
  else:
    qres = pqsendQueryParams(conn.pgconn, query, pN, pT, pV, pL, pF, rF)

  if qres == 0:
    raise newException(ValueError, $pqerrorMessage(conn.pgconn))

  while true:
    while true:
      let fr = pqflush(conn.pgconn)
      if fr < 0:
        raise newException(ValueError, $pqerrorMessage(conn.pgconn))
      if fr == 0:
        break
      waitWritable(fd)
    var execDone = false
    if pqconsumeInput(conn.pgconn) == 0:
      raise newException(ValueError, $pqerrorMessage(conn.pgconn))
    processPendingNotifications(conn, notifyConn)
    while pqisBusy(conn.pgconn) == 0:
      var res = pqgetResult(conn.pgconn)
      if res != nil:
        let stres = pqresultStatus(res)
        case stres
        of PGRES_EMPTY_QUERY, PGRES_COMMAND_OK, PGRES_TUPLES_OK:
          apgres.pgress.add(res)
        of PGRES_COPY_IN, PGRES_COPY_OUT:
          apgres.pgress.add(res)
          execDone = true
          break
        else:
          raise newException(ValueError, $pqerrorMessage(conn.pgconn))
      else:
        execDone = true
        break
    if execDone:
      return apgres
    waitReadable(fd)

proc execPoolAsync(pool: ApgPool, statement: string, pN: int32, pT: POid,
                   pV: cstringArray, pL, pF: ptr int32,
                   rF: int32): ApgResult {.flow.} =
  let index = checkout(pool)
  try:
    result = execAsync(pool.connections[index], statement, pN, pT,
                       pV, pL, pF, rF, false)
    forwardConnNotifiesToPool(pool.connections[index], pool.notifies)
  except CatchableError as e:
    if pool.connections[index] != nil and pool.connections[index].pgconn != nil:
      pqfinish(pool.connections[index].pgconn)
      pool.connections[index].pgconn = nil
      pool.connections[index] = nil
    raise e
  finally:
    checkin(pool, index)

# `exec` expands to `execDispatch` (or, for other pool types, their own async proc);
# overloading on the first argument picks the right implementation.
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

proc close*(apgres: ApgResult) =
  ## Closes query results stored inside ``apgres``.

  for pgr in apgres.pgress:
    pqclear(pgr)
  apgres.pgress.setLen(0)

proc `[]`*(apgres: ApgResult, index: int): PPGresult =
  ## Returns query result from ``apgres`` by ``index``.

  result = apgres.pgress[index]

template setRow(pgres: PPGresult, r, line, cols) =
  for col in 0..<cols:
    let x = pqgetvalue(pgres, line.int32, col.int32)
    if x.isNil:
      r[col] = "" # nil
    else:
      r[col] = $x

template setRowInline(pgres: PPGresult, r, line, cols) =
  for col in 0..<cols:
    setLen(r[col], 0)
    let x = pqgetvalue(pgres, line.int32, col.int32)
    if x.isNil:
      r[col] = "" # nil
    else:
      add(r[col], x)

proc getValue*(pgres: PPGresult): string =
  ## Returns single value from result ``pgres``.

  var x = pqgetvalue(pgres, 0, 0)
  result = if isNil(x): "" else: $x


proc getRow*(pgres: PPGresult): Row =
  ## Returns ``Row`` value from result ``pgres``.

  var L = pqnfields(pgres)
  result = newSeq[string](L)
  setRow(pgres, result, 0, L)
  pqclear(pgres)

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

  result = parseBiggestInt($pqcmdTuples(pgres))

proc setClientEncoding*(conn: ApgConnection,
                        encoding: string) {.flow.} =
  ## Sets the client encoding.

  var statement = "set client_encoding to '" & encoding & "'"
  var ares = execAsync(conn, statement, 0, nil, nil, nil, nil, 0)
  if pqresultStatus(ares.pgress[0]) != PGRES_COMMAND_OK:
    raise newException(ValueError, $pqerrorMessage(conn.pgconn))
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

#
# exec macro
#

# shows error with linenumber and column for argument caused error
proc showError(s: string, n: NimNode = nil) {.compileTime.} =
  if isNil(n):
    error(s)
  else:
    error(s & ", at " & lineinfo(n))
# var <n> = <v>
proc newVarArray(n, v: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(n, newEmptyNode(), v)
  )
# cast[pointer](addr <n>)
proc castPointer(n: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkCast).add(
    newIdentNode("pointer"),
    newNimNode(nnkCommand).add(newIdentNode("addr"), n)
  )
# cast[<v>](addr <n>[0])
proc castPointer0(n: NimNode, v: string): NimNode {.compileTime.} =
  result = newNimNode(nnkCast).add(
    newIdentNode(v),
    newNimNode(nnkCommand).add(
      newIdentNode("addr"),
      newNimNode(nnkBracketExpr).add(n, newLit(0))
    )
  )
# <v>.Oid
proc castOid(v: int): NimNode {.compileTime.} =
  result = newDotExpr(newLit(v), newIdentNode("Oid"))
# len(<v>)
proc callLength(n: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkCall).add(newIdentNode("len"), n)
# size(<v>)
proc callSize(n: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkCall).add(newIdentNode("size"), n)
# raw(<v>)
proc callRaw(n: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkCall).add(newIdentNode("raw"), n)
# cast[<v>](n)
proc castSome(n: NimNode, v: string): NimNode {.compileTime.} =
  result = newNimNode(nnkCast).add(newIdentNode(v), n)

proc endianPrepareCall(v: NimNode): NimNode {.compileTime.} =
  ## Qualified call so it cannot resolve to stagelane's `prepare` macro.
  ## Use ``byteswap.prepare`` explicitly so we do not pick up stagelane's ``prepare``.
  result = quote do:
    byteswap.prepare(`v`)

# var <n> = prepare(<v>)
proc newVarInteger(n, v: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(
      n, newEmptyNode(), endianPrepareCall(v)
    )
  )
# var <n> = <v>
proc newVarSimple(n, v: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(n, newEmptyNode(), v)
  )
# var <n> = cast[<i>](<v>)
proc newVarCast(n, i, v: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(
      n, newEmptyNode(), newNimNode(nnkCast).add(v, i)
    )
  )
# var <n> = <c>()
proc newVarExec(n, c: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(n, newEmptyNode(), c)
  )
# var <n> = $(<v>)
proc newVarStringify(n, v: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(n, newEmptyNode(),
      newNimNode(nnkPrefix).add(
        newIdentNode("$"),
        newNimNode(nnkPar).add(v)
      )
    )
  )

# var <n> = prepare(cast[<i>](<v>))
proc newVarFloat(n, i, v: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(
      n, newEmptyNode(),
      endianPrepareCall(newNimNode(nnkCast).add(v, i))
    )
  )
# var <n> = newPgArray((<v>))
proc newVarSeq(n, v: NimNode, s: string): NimNode {.compileTime.} =
  result = newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(
      n, newEmptyNode(),
      newCall(
        newNimNode(nnkBracketExpr).add(
          newIdentNode("newPgArray"),
          newIdentNode(s)
        ), v, newIdentNode("true")
      )
    )
  )
# var <n> = newPgJson((<v>))
proc newVarJson(n, v: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(
      n, newEmptyNode(), newCall(newIdentNode("newPgJson"), v)
    )
  )
# addr(<n>[0])
proc newAddr0(n: NimNode): NimNode {.compileTime.} =
  result = newNimNode(nnkCommand).add(
             newIdentNode("addr"),
             newNimNode(nnkBracketExpr).add(n, newLit(0))
           )
# this is copy of newLit(int) but makes int32
proc newLit(i: int32): NimNode {.compileTime.} =
  ## produces a new integer literal node.
  result = newNimNode(nnkInt32Lit)
  result.intVal = i
# echo(repr(<n>))
# proc newEchoVar(n: NimNode): NimNode {.compileTime.} =
#   result = newNimNode(nnkCall).add(
#     newIdentNode("echo"),
#     newNimNode(nnkCall).add(newIdentNode("repr"), n)
#   )
proc `$`(ntyType: NimTypeKind): string =
  var names = ["int", "int8", "int16", "int32", "int64", "float", "float32",
               "float64", "", "uint", "uint8", "uint16", "uint32", "uint64"]
  case ntyType
    of ntyBool:
      result = "bool"
    of ntyChar:
      result = "char"
    of ntyString:
      result = "string"
    of ntyInt..ntyFloat64, ntyUint..ntyUInt64:
      result = names[ntyType.int - ntyInt.int]
    else:
      result = ""

# This procedure converts Nim's array/sequence type to appropriate
# PostgreSQL Array Type Oid.
#
# Currently supported array/sequences:
# array/seq[bool] => ARRAY[bool] (1000)
# array/seq[char, uint8, int8] => BYTEA (17)
# array/seq[int16, uint16] => ARRAY[int2] (1005)
# array/seq[int32, uint32] => ARRAY[int4] (1007)
# array/seq[int64, uint64] => ARRAY[int8] (1016)
# array/seq[float32] => ARRAY[float4] (1021)
# array/seq[float64] => ARRAY[float8] (1022)
# array/seq[float] => ARRAY[float8] (1022)
# array/seq[int, uint] => ARRAY[int2, int4, int8] (1005, 1007, 1016)
# depends on platform's size of int
# array/seq[string] => ARRAY[text] (1009)
# array/seq[cstring] => ARRAY[text] (1009)
proc getOidArray(ntyType: NimTypeKind): int {.compileTime.} =
  case ntyType
  of ntyBool:
    result = 1000
  of ntyInt16, ntyUInt16:
    result = 1005
  of ntyInt32, ntyUInt32:
    result = 1007
  of ntyInt64, ntyUInt64:
    result = 1016
  of ntyFloat32:
    result = 1021
  of ntyFloat64:
    result = 1022
  of ntyFloat:
    result = 1022
  of ntyInt, ntyUInt:
    when sizeof(int) == 8:
      result = 1016
    elif sizeof(int) == 4:
      result = 1007
    elif sizeof(int) == 2:
      result = 1005
    else:
      showError("Unsupported int size!")
  of ntyString, ntyCString:
    result = 1009
  else:
    showError("Unsupported array oid type!")

# This procedure converts Nim's type to appropriate
# PostgreSQL type Oid.
#
# Currently supported types:
# bool => bool(16)
# char => char(18)
# int8, uint8 => char(18)
# int16, uint16 => int2(21)
# int32, uint32 => int4(23)
# int64, uint64 => int8(20)
# float32 => float4(700)
# float64 => float8(701)
# float => float8(701), float type is always float64 in nim.
# int => int8(20), int4(23), int2(21), depends on platform's size of `int`
# uint => int8(20), int4(23), int2(21), depends on platform's size of `int`
proc getOidSimple(ntyType: NimTypeKind):
                  tuple[oid: int, size: int] {.compileTime.} =
  case ntyType
  of ntyBool:
    result = (oid: 16, size: 1)
  of ntyChar, ntyInt8, ntyUInt8:
    result = (oid: 18, size: 1)
  of ntyInt16, ntyUInt16:
    result = (oid: 21, size: 2)
  of ntyInt32, ntyUInt32:
    result = (oid: 23, size: 4)
  of ntyInt64, ntyUInt64:
    result = (oid: 20, size: 8)
  of ntyFloat32:
    result = (oid: 700, size: 4)
  of ntyFloat64:
    result = (oid: 701, size: 8)
  of ntyInt:
    when sizeof(int) == 8:
      result = (oid: 20, size: 8)
    elif sizeof(int) == 4:
      result = (oid: 23, size: 4)
    elif sizeof(int) == 2:
      result = (oid: 21, size: 2)
    else:
      result = (oid: -1, size: -1)
  of ntyUInt:
    when sizeof(int) == 8:
      result = (oid: 20, size: 8)
    elif sizeof(int) == 4:
      result = (oid: 23, size: 4)
    elif sizeof(int) == 2:
      result = (oid: 21, size: 2)
    else:
      result = (oid: -1, size: -1)
  of ntyFloat:
    result = (oid: 701, size: 8)
  else:
    result = (oid: -1, size: -1)

# This procedure process sequences and arrays
proc getSequence(ls, ps, op, ntp, np, pv, pl, pt, pf: NimNode) {.compileTime.} =
  var impType = ntp.typeKind
  case impType
  of ntyChar, ntyInt8, ntyUInt8:
    if op.kind == nnkSym:
      pv.add(castPointer0(op, "pointer"))
      pl.add(castSome(callLength(op), "int32"))
      pt.add(castOid(17)) # bytea
      pf.add(newLit(1'i32))
    else:
      ls.add(newVarSimple(np, op))
      pv.add(castPointer0(np, "pointer"))
      pl.add(castSome(callLength(np), "int32"))
      pt.add(castOid(17)) # bytea
      pf.add(newLit(1'i32))
  of ntyBool, ntyInt, ntyUInt, ntyInt16..ntyInt64, ntyUInt16..ntyUInt64,
     ntyFloat..ntyFloat64, ntyString:
    ls.add(newVarSeq(np, op, $impType))
    pv.add(callRaw(np))
    pl.add(castSome(callSize(np), "int32"))
    pt.add(castOid(getOidArray(impType)))
    pf.add(newLit(1'i32))
    ps.add(newCall(newIdentNode("free"), np))
  else:
    showError("Argument's type `seq[" & $impType & "]`is not supported", op)

macro apgExecImpl*(dispatch: static[string], conn: typed, statement: string,
                    params: varargs[typed]): untyped =
  ## Build the statement list for ``exec``; ``dispatch`` is the async proc name
  ## (``execDispatch`` for connections and ``ApgPool``, or ``execSharedPoolAsync``).
  let dispatchId = ident(dispatch)
  if len(params) == 0:
    result = newTree(nnkStmtListExpr,
               newCall(dispatchId, conn, statement, newLit 0,
                       newNimNode(nnkNilLit), newNimNode(nnkNilLit),
                       newNimNode(nnkNilLit), newNimNode(nnkNilLit),
                       newLit(0))
             )
  else:
    result = newTree(nnkStmtListExpr)

    var postNodes = newNimNode(nnkStmtList)
    var execResultVar = genSym(nskVar, "execResultVar")

    var typesList = newNimNode(nnkBracket)
    var valuesList = newNimNode(nnkBracket)
    var lensList = newNimNode(nnkBracket)
    var formatsList = newNimNode(nnkBracket)

    var typesName = genSym(nskVar, "execTypes")
    var valuesName = genSym(nskVar, "execValues")
    var lensName = genSym(nskVar, "execLens")
    var formatsName = genSym(nskVar, "execFormats")

    var typesArray = newVarArray(typesName, typesList)
    var valuesArray = newVarArray(valuesName, valuesList)
    var lensArray = newVarArray(lensName, lensList)
    var formatsArray = newVarArray(formatsName, formatsList)
    var idx = 0

    for param in params:
      var np = genSym(nskVar, "param" & $idx)
      let kiType = getType(param).typeKind
      case kiType
        of ntyBool:
          let oid = getOidSimple(kiType)
          result.add(newVarCast(np, param, newIdentNode("int8")))
          valuesList.add(castPointer(np))
          lensList.add(newLit(oid.size.int32))
          typesList.add(castOid(oid.oid))
          formatsList.add(newLit(1.int32))
        of ntyChar, ntyInt8, ntyUInt8:
          let oid = getOidSimple(kiType)
          result.add(newVarSimple(np, param))
          valuesList.add(castPointer(np))
          lensList.add(newLit(oid.size.int32))
          typesList.add(castOid(oid.oid))
          formatsList.add(newLit(1.int32))
        of ntyInt, ntyUInt, ntyInt16..ntyInt64, ntyUInt16..ntyUInt64:
          let oid = getOidSimple(kiType)
          result.add(newVarInteger(np, param))
          valuesList.add(castPointer(np))
          lensList.add(newLit(oid.size.int32))
          typesList.add(castOid(oid.oid))
          formatsList.add(newLit(1.int32))
        of ntyFloat..ntyFloat64:
          let oid = getOidSimple(kiType)
          var nident: NimNode
          if kiType == ntyFloat or kiType == ntyFloat64:
            nident = newIdentNode("int64")
          else:
            nident = newIdentNode("int32")
          result.add(newVarFloat(np, param, nident))
          valuesList.add(castPointer(np))
          lensList.add(newLit(oid.size.int32))
          typesList.add(castOid(oid.oid))
          formatsList.add(newLit(1.int32))
        of ntyString, ntyCString:
          if param.kind == nnkStrLit:
            result.add(newVarSimple(np, param))
            valuesList.add(castPointer0(np, "pointer"))
            lensList.add(castSome(callLength(np), "int32"))
          else:
            valuesList.add(castPointer0(param, "pointer"))
            lensList.add(castSome(callLength(param), "int32"))
          typesList.add(castOid(25))
          formatsList.add(newLit(1.int32))
        of ntySequence:
          var imp = getTypeImpl(param)
          var ntp = getType(imp[1])
          getSequence(result, postNodes, param, ntp, np, valuesList,
                      lensList, typesList, formatsList)
        of ntyArray:
          var imp = getTypeImpl(param)
          var ntp = getType(imp[2])
          getSequence(result, postNodes, param, ntp, np, valuesList,
                      lensList, typesList, formatsList)
        of ntyDistinct:
          var name = getTypeInst(param).strVal
          case name
          of "JsonB":
            result.add(newVarJson(np, param[1]))
            valuesList.add(callRaw(np))
            lensList.add(castSome(callSize(np), "int32"))
            typesList.add(castOid(3802))
            formatsList.add(newLit(1'i32))
            postNodes.add(newCall(newIdentNode("free"), np))
          of "Json":
            result.add(newVarStringify(np, param[1]))
            valuesList.add(castPointer0(np, "pointer"))
            lensList.add(castSome(callLength(np), "int32"))
            typesList.add(castOid(114)) # json oid
            formatsList.add(newLit(1.int32))
          else:
            showError("Argument's type is not supported", param)
        of ntyRef:
          var name = getTypeInst(param).strVal
          if name == "JsonNode":
            if param.kind == nnkPrefix:
              var jsonCompiled = genSym(nskLet, "jsonCompiled" & $idx)
              result.add(newLetStmt(jsonCompiled, param))
              result.add(newVarStringify(np, jsonCompiled))
            else:
              result.add(newVarStringify(np, param))
            valuesList.add(castPointer0(np, "pointer"))
            lensList.add(castSome(callLength(np), "int32"))
            typesList.add(castOid(114)) # json oid
            formatsList.add(newLit(1.int32))
          else:
            showError("Argument's type object of `" & name & "`is not supported",
                      param)
        else:
          showError("Argument's type is not supported", param)
      inc(idx)

    result.add(
      valuesArray, typesArray, lensArray, formatsArray,
      newVarExec(execResultVar,
        newCall(dispatchId, conn, statement,
                newLit len(params), castPointer0(typesName, "POid"),
                castPointer0(valuesName, "cstringArray"),
                newAddr0(lensName), newAddr0(formatsName), newLit(0)))
    )
    for child in postNodes.children:
      result.add(child)
    result.add(execResultVar)

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

template checkResultCommand(res) =
  var sres = pqresultStatus(res.pgress[0])
  close(res)
  if sres != PGRES_COMMAND_OK:
    raise newException(ValueError, $pqerrorMessage(res.pgress[0].conn))

template checkResultTuple(res) =
  var sres = pqresultStatus(res.pgress[0])
  close(res)
  if sres != PGRES_TUPLES_OK:
    raise newException(ValueError, $pqerrorMessage(res.pgress[0].conn))

proc listenNotify*(conn: ApgConnection,
                   channel: string) {.flow.} =
  ## Registers listening for asynchronous notifies on connection ``conn`` and
  ## channel ``channel``.

  var query = "LISTEN \"" & channel & "\";"
  var res = exec(conn, query)
  checkResultCommand(res)

proc listenNotify*(pool: ApgPool,
                   channel: string) {.flow.} =
  ## Registers listening for asynchronous notifies on pool ``pool`` and
  ## channel ``channel``.

  var query = "LISTEN \"" & channel & "\";"
  var res = exec(pool, query)
  checkResultCommand(res)

proc unlistenNotify*(conn: ApgConnection,
                     channel: string) {.flow.} =
  ## Unregisters listening for asynchronous notifies on connection ``conn`` and
  ## channel ``channel``.

  var query = "UNLISTEN \"" & channel & "\";"
  var res = exec(conn, query)
  checkResultCommand(res)

proc unlistenNotify*(pool: ApgPool,
                     channel: string) {.flow.} =
  ## Unregisters listening for asynchronous notifies on pool ``pool`` and
  ## channel ``channel``.

  var query = "UNLISTEN \"" & channel & "\";"
  var res = exec(pool, query)
  checkResultCommand(res)

proc sendNotify*(conn: ApgConnection, channel: string,
                 payload: string) {.flow.} =
  ## Send asynchronous notify to channel ``channel`` with data in ``payload``.
  ## Be sure size of ``payload`` must be less, than 8000 bytes.

  # https://www.postgresql.org/docs/9.0/static/sql-notify.html
  doAssert(len(payload) < 8000)

  var p1 = channel
  var p2 = payload
  var query = "SELECT pg_notify($1, $2);"
  var res = exec(conn, query, p1, p2)
  checkResultTuple(res)

proc sendNotify*(pool: ApgPool, channel: string,
                 payload: string) {.flow.} =
  ## Send asynchronous notify to channel ``channel`` with data in ``payload``.
  ## Be sure size of ``payload`` must be less, than 8000 bytes.

  # https://www.postgresql.org/docs/9.0/static/sql-notify.html
  doAssert(len(payload) < 8000)

  var p1 = channel
  var p2 = payload
  var query = "SELECT pg_notify($1, $2);"
  var res = exec(pool, query, p1, p2)
  checkResultTuple(res)

proc notify*(conn: ApgConnection|ApgPool, channel: string): NotifyWait =
  ## Register to wait for NOTIFY on ``channel``. Call `waitNotify` from a
  ## `{.flow.}` context after NOTIFY is sent.

  var cell = ApgNotifyCell()
  var w = NotifyWait()
  w.channel = channel
  w.q = newWaitQueue()
  w.arrived = false
  cell.wait = w
  conn.notifies.append(cell)
  return w

proc waitNotify*(w: NotifyWait): ApgNotify {.flow.} =
  ## Block until the NOTIFY registered by `notify` arrives.
  while not w.arrived:
    # Snapshot the epoch before re-checking `arrived`: a notify from another thread
    # between the check and the park bumps it, so `parkSince` returns immediately.
    let e = epochOf(w.q)
    if not w.arrived:
      parkSince(w.q, e)
  return w.ntf

#
# Escape functions
#

proc pqescapeLiteral(conn: PPGconn, bintext: cstring, binlen: int): cstring
     {.cdecl, dynlib: dllName, importc: "PQescapeLiteral".}
proc pqescapeByteaConn(conn: PPGconn, bintext: cstring, binlen :int,
                       resultlen: ptr int): cstring
     {.cdecl, dynlib: dllName, importc: "PQescapeByteaConn".}

proc escapeString*(conn: ApgConnection, str: string): string =
  ## Escapes a string for use within an SQL command according to rules
  ## of connection `conn`.
  var r = pqescapeLiteral(conn.pgconn, cstring(str), len(str))
  if isNil(r):
    raise newException(ValueError, $pqerrorMessage(conn.pgconn))
  else:
    result = $r
    pqfreemem(cast[pointer](r))

proc escapeBytea*(conn: ApgConnection, buf: pointer, size: int): string =
  ## Converts binary data from pointer `buf` and length `size` to
  ## PostgreSQL's BYTEA string representation.
  var s = 0
  var r = pqescapeByteaConn(conn.pgconn, cast[cstring](buf), size, addr s)
  if isNil(r):
    raise newException(ValueError, $pqerrorMessage(conn.pgconn))
  else:
    result = $r
    pqfreemem(cast[pointer](r))

proc unescapeBytea*(str: string): seq[char] =
  ## Converts PostgreSQL's BYTEA string representation to seq[char].
  var n = 0
  var r = pqunescapeBytea(cstring(str), n)
  doAssert(r != nil)
  result = newSeq[char](n)
  copyMem(addr result[0], r, n)
  pqfreemem(cast[pointer](r))

