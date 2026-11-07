## Compile-time mapping between Nim types and PostgreSQL type OIDs, used by the
## `exec` macro. Nim's `int`/`uint` follow the platform word size, so they map to
## int8/int4/int2 accordingly. `uint64` is sent as int8 and is not range checked.

import macros

# shows error with linenumber and column for argument caused error
proc showError*(s: string, n: NimNode = nil) {.compileTime.} =
  if isNil(n):
    error(s)
  else:
    error(s & ", at " & lineinfo(n))

proc `$`*(ntyType: NimTypeKind): string =
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
proc getOidArray*(ntyType: NimTypeKind): int {.compileTime.} =
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
proc getOidSimple*(ntyType: NimTypeKind):
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

