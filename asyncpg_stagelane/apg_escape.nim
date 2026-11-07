## Escaping helpers bound to a connection.

import db_connector/postgres
import apg_errors, apg_ffi, apg_core

proc escapeString*(conn: ApgConnection, str: string): string =
  ## Escapes a string for use within an SQL command according to rules
  ## of connection `conn`.
  var r = pqescapeLiteral(pgconn(conn), cstring(str), len(str))
  if isNil(r):
    raiseConnError(pgconn(conn))
  else:
    result = $r
    pqfreemem(cast[pointer](r))

proc escapeBytea*(conn: ApgConnection, buf: pointer, size: int): string =
  ## Converts binary data from pointer `buf` and length `size` to
  ## PostgreSQL's BYTEA string representation.
  var s = 0
  var r = pqescapeByteaConn(pgconn(conn), cast[cstring](buf), size, addr s)
  if isNil(r):
    raiseConnError(pgconn(conn))
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

