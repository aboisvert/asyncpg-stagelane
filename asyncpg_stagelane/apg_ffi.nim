## libpq symbols missing from db_connector, plus the shared library name.

import db_connector/postgres

when defined(windows):
  const dllName* = "libpq.dll"
elif defined(macosx):
  # Homebrew's libpq is keg-only. Point dyld at it before launch, for example:
  #   export DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix libpq)/lib"
  const dllName* = "libpq.dylib"
else:
  const dllName* = "libpq.so(.5|)"

proc pgEncodingToChar*(encoding: int32): cstring
     {.cdecl, dynlib: dllName, importc: "pg_encoding_to_char"}
proc pqlibVersion*(): cint
     {.cdecl, dynlib: dllName, importc: "PQlibVersion".}
proc pqisthreadsafe*(): cint
     {.cdecl, dynlib: dllName, importc: "PQisthreadsafe".}

proc pqescapeLiteral*(conn: PPGconn, bintext: cstring, binlen: int): cstring
     {.cdecl, dynlib: dllName, importc: "PQescapeLiteral".}
proc pqescapeByteaConn*(conn: PPGconn, bintext: cstring, binlen :int,
                       resultlen: ptr int): cstring
     {.cdecl, dynlib: dllName, importc: "PQescapeByteaConn".}
