#
#
#                    AsyncPG
#        (c) Copyright 2016 Eugene Kabanov
#
#    See the file "LICENSE", included in this
#    distribution, for details about the copyright.
#

## Host to network (big endian) byte order conversion.
##
## `hton` swaps in place of the old per-OS table of intrinsics: every supported
## compiler provides `__builtin_bswap*` (gcc, clang) or `_byteswap_*` (MSVC),
## and anything else falls back to portable shifts.

when defined(gcc) or defined(clang) or defined(llvm_gcc):
  func bswap32(x: uint32): uint32 {.importc: "__builtin_bswap32", nodecl.}
  func bswap64(x: uint64): uint64 {.importc: "__builtin_bswap64", nodecl.}
elif defined(vcc):
  func bswap32(x: uint32): uint32
       {.importc: "_byteswap_ulong", header: "<stdlib.h>".}
  func bswap64(x: uint64): uint64
       {.importc: "_byteswap_uint64", header: "<stdlib.h>".}
else:
  func bswap32(x: uint32): uint32 =
    (x shl 24) or ((x and 0xFF00'u32) shl 8) or
      ((x shr 8) and 0xFF00'u32) or (x shr 24)
  func bswap64(x: uint64): uint64 =
    (uint64(bswap32(uint32(x))) shl 32) or uint64(bswap32(uint32(x shr 32)))

# Dispatch is on size at compile time. Floats work because only the bit pattern
# is swapped (cast), never the numeric value.
template hton*[T: SomeNumber | bool | char](x: T): T =
  ## Converts `x` to network byte order (no-op for 1 byte types and on
  ## big endian hosts). Works for floats by swapping their bit pattern.
  when cpuEndian == bigEndian or sizeof(T) == 1:
    x
  elif sizeof(T) == 2:
    cast[T]((cast[uint16](x) shr 8) or (cast[uint16](x) shl 8))
  elif sizeof(T) == 4:
    cast[T](bswap32(cast[uint32](x)))
  else:
    cast[T](bswap64(cast[uint64](x)))

template prepare*[T: SomeNumber | bool | char](x: T): T =
  ## Old name of `hton`, kept for compatibility.
  hton(x)
