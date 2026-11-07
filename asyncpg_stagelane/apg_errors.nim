## Error types and the single place where libpq failures become exceptions.

import db_connector/postgres, strutils

type
  ApgError* = object of ValueError
    ## Base type of every error raised by this driver (derives from
    ## `ValueError` so pre-existing `except ValueError` handlers keep working).
  ApgConnectionError* = object of ApgError
    ## Connection-level failure (socket, auth, protocol).
  ApgQueryError* = object of ApgError
    ## The server rejected a statement.
    sqlState*: string ## five character SQLSTATE, empty if unknown

proc raiseConnError*(c: PPGconn) {.noreturn.} =
  raise newException(ApgConnectionError, $pqerrorMessage(c))

proc raiseResultError*(r: PPGresult) {.noreturn.} =
  ## Raises `ApgQueryError` for the failed result `r` and takes ownership of it
  ## (it is cleared before raising).
  let e = newException(ApgQueryError, $pqresultErrorMessage(r))
  let st = pqresultErrorField(r, int32('C'))   # PG_DIAG_SQLSTATE
  if st != nil: e.sqlState = $st
  pqclear(r)
  raise e

func quoteIdent*(s: string): string =
  ## Quotes `s` as an SQL identifier (channel names etc.).
  if '\0' in s:
    raise newException(ValueError, "NUL byte in identifier")
  result = "\"" & s.replace("\"", "\"\"") & "\""
