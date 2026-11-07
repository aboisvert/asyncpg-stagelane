## Compile-time binding of Nim values to libpq binary parameters (`apgExecImpl`).
##
## Every argument is sent in binary format with an explicit type OID, so integers
## and floats must be converted to network byte order and strings/bytea are passed
## by pointer and length (no NUL terminator, no escaping). Arrays and JSONB are
## encoded into heap buffers that the generated code frees after the call.
##
## The generated code refers to `ApgResult`, `newPgArray`, `newPgJson`, `free`,
## `raw`, `size` and `seqDataPtr`, which are resolved where `exec` is used.

import macros, json
import apg_array, byteswap, apg_oids


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
  ## Qualified so it cannot resolve to stagelane's `prepare` macro.
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
var emptyParamByte: byte  ## valid address for zero-length bytea parameters

template seqDataPtr*(x: untyped): pointer =
  ## Address of the first element of `x` (a template, so no copy is taken).
  if x.len == 0: cast[pointer](addr emptyParamByte)
  else: cast[pointer](unsafeAddr x[0])

# This procedure process sequences and arrays
proc getSequence(ls, ps, op, ntp, np, pv, pl, pt, pf: NimNode) {.compileTime.} =
  var impType = ntp.typeKind
  case impType
  of ntyChar, ntyInt8, ntyUInt8:
    # Bind non-symbols once; `seqDataPtr` is safe for empty sequences (a nil
    # pointer would be sent as SQL NULL, so it returns a valid dummy address).
    var src = op
    if op.kind != nnkSym:
      ls.add(newVarSimple(np, op))
      src = np
    pv.add(newCall(newIdentNode("seqDataPtr"), src))
    pl.add(castSome(callLength(src), "int32"))
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
          # Nim bool is 1 byte but not guaranteed 0/1 in the C sense; send an int8.
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
          # Floats are byteswapped via an integer of the same width.
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
          # Bind non-symbols once (literals, calls, `a & b`). `cstring(x)` is
          # valid for empty strings, unlike `addr x[0]`.
          var src = param
          if param.kind != nnkSym:
            result.add(newVarSimple(np, param))
            src = np
          valuesList.add(castSome(newCall(newIdentNode("cstring"), src), "pointer"))
          lensList.add(castSome(callLength(src), "int32"))
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
          # `Json`/`JsonB` are the only supported distinct types; `JsonNode(x)`
          # converts back so any expression of that type works.
          var name = getTypeInst(param).strVal
          case name
          of "JsonB":
            result.add(newVarJson(np, newCall(newIdentNode("JsonNode"), param)))
            valuesList.add(callRaw(np))
            lensList.add(castSome(callSize(np), "int32"))
            typesList.add(castOid(3802))
            formatsList.add(newLit(1'i32))
            postNodes.add(newCall(newIdentNode("free"), np))
          of "Json":
            result.add(newVarStringify(np, newCall(newIdentNode("JsonNode"), param)))
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
              # `%*` literals expand to a block; evaluate once into a `let`.
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

    let callNode = newCall(dispatchId, conn, statement,
                newLit len(params), castPointer0(typesName, "POid"),
                castPointer0(valuesName, "cstringArray"),
                newAddr0(lensName), newAddr0(formatsName), newLit(0))
    # The arrays live in `result` (not in the call) so their addresses stay valid
    # for the whole dispatch call.
    result.add(valuesArray, typesArray, lensArray, formatsArray,
               newNimNode(nnkVarSection).add(newNimNode(nnkIdentDefs).add(
                 execResultVar, newIdentNode("ApgResult"), newEmptyNode())))
    # Free binary parameter buffers even when the call raises.
    let assign = newAssignment(execResultVar, callNode)
    if postNodes.len > 0:
      result.add(newTree(nnkTryStmt, newStmtList(assign),
                         newTree(nnkFinally, postNodes)))
    else:
      result.add(assign)
    result.add(execResultVar)

