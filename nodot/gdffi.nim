import std/[macros, options]

import ./ffi
import ../nodot
import ./builtins/variant
import ./helpers

import ./builtins/types
import ./classes/types/"object"

export helpers.toGodotStringName

# Called in the second run-around of the macro expansion once type information
# is available to determine if we are dealing with an object type or a builtin
template getResultPtr*(): pointer {.dirty.} =
  when compiles(result of ObjectObj):
    new(result)

    addr result.opaque
  else:
    addr result

func getFuncResultPtr(prototype: NimNode): NimNode =
  if prototype[3][0].kind == nnkEmpty:
    newNilLit()
  else:
    if prototype[3][0].getType is Object:
      newEmptyNode()
    else:
      newCall(ident("getResultPtr"))

func getSelfPtr(prototype: NimNode; asPtr: bool = true): NimNode =
  if len(prototype[3]) > 1 and prototype[3][1][0] == "_".ident():
    newNilLit()
  else:
    let ident = prototype[3][1][0]

    if not asPtr:
      return newDotExpr(ident, "opaque".ident())

    if prototype[3][1][^2].kind == nnkVarTy:
      newCall(ident("addr"), ident)
    else:
      newCall(ident("unsafeAddr"), ident)

func getSelfType(prototype: NimNode): NimNode =
  if len(prototype[3]) > 1 and prototype[3][1][0] == "_".ident():
    prototype[3][1][1][1]
  else:
    if prototype[3][1][^2].kind == nnkVarTy:
      prototype[3][1][1][0]
    else:
      prototype[3][1][1]



func getVarArgs(prototype: NimNode): Option[NimNode] =
  if len(prototype[3]) > 1:
    let lastArg = prototype[3][^1]

    if lastArg[1].kind == nnkBracketExpr and lastArg[1][0].strVal == "varargs":
      return some lastArg

  none NimNode

func genArgsList(prototype: NimNode; argc: ptr int; ignoreFirst: bool = false): NimNode =
  result = newTree(nnkBracket)

  # If the first parameter is a typedesc[T] marker, skip it
  var skip = if len(prototype[3]) > 1 and prototype[3][1][0] == "_".ident():
    2
  else:
    # We ignore the first arg for (non-builtin) class methods because the instance
    # pointer is passed as separate argument.
    if ignoreFirst:
      2
    else:
      1

  # Do not include the varargs here, they are handled specially
  let drop = if getVarArgs(prototype).isSome():
    1
  else:
    0

  if skip > len(prototype[3]) - 1:
    return

  for formalArgs in prototype[3][skip..^(1 + drop)]:
    for formalArg in formalArgs[0..^3]:
      inc argc[]

      result.add quote do:
        pointer(unsafeAddr `formalArg`)

macro gd_utility*(hash: static[int64]; prototype: untyped) =
  let functionName = prototype[0][1].strVal()

  var argc: int

  let resultPtr = prototype.getFuncResultPtr()
  let varArgs = prototype.getVarArgs()
  let args = prototype.genArgsList(addr argc)

  result = prototype

  if varArgs.isNone():
    result[^1] = quote do:
      var p {.global.} = block:
        var gdFuncName = `functionName`.toGodotStringName()

        try:
          gdInterfacePtr.variant_get_ptr_utility_function(addr gdFuncName, `hash`)
        finally:
          destroyStringName gdFuncName

      var argPtrs: array[`argc`, GDExtensionConstTypePtr] = `args`

      p(
        cast[GDExtensionTypePtr](`resultPtr`),
        cast[ptr GDExtensionConstTypePtr](addr argPtrs),
        cint(`argc`))
  else:
    let varArgId = varArgs.unsafeGet()[0]

    result[^1] = quote do:
      var p {.global.} = block:
        var gdFuncName = `functionName`.toGodotStringName()

        try:
          gdInterfacePtr.variant_get_ptr_utility_function(addr gdFuncName, `hash`)
        finally:
          destroyStringName gdFuncName

      var argPtrs = @`args`

      for i in 0..high(`varArgId`):
        argPtrs &= pointer(unsafeAddr `varArgId`[i])

      p(
        cast[GDExtensionTypePtr](`resultPtr`),
        cast[ptr GDExtensionConstTypePtr](addr argPtrs[0]),
        cint(`argc` + len(`varArgId`)))

macro gd_builtin_ctor*(ty: typed; idx: static[int]; prototype: untyped) =
  var argc: int
  let args = prototype.genArgsList(addr argc)

  result = prototype
  result[^1] = quote do:
    var p {.global.} = gdInterfacePtr.variant_get_ptr_constructor(
      `ty`.variantTypeId, int32(`idx`))

    var argPtrs: array[`argc`, GDExtensionConstTypePtr] = `args`

    p(addr result, cast[ptr GDExtensionConstTypePtr](addr argPtrs))

macro gd_builtin_dtor*(ty: typed; prototype: untyped) =
  let selfPtr = prototype.getSelfPtr()

  result = prototype
  result[^1] = quote do:
    var p {.global.} = gdInterfacePtr.variant_get_ptr_destructor(
      `ty`.variantTypeId)

    p(cast[GDExtensionTypePtr](`selfPtr`))

func getNameFromProto(proto: NimNode): string =
  if proto[0][1].kind == nnkIdent:
    proto[0][1].strVal()
  else:
    # `quoted`
    proto[0][1][0].strVal()

# TODO: varargs
macro gd_builtin_method*(ty: typed; hash: static[int64]; prototype: untyped) =
  let functionName = prototype.getNameFromProto()

  var argc: int

  let selfPtr = prototype.getSelfPtr()
  let resultPtr = prototype.getFuncResultPtr()
  let args = prototype.genArgsList(addr argc)
  let varArgs = prototype.getVarArgs()

  result = prototype

  if varArgs.isNone():
    result[^1] = quote do:
      var p {.global.} = block:
        var gdFuncName = `functionName`.toGodotStringName()

        try:
          gdInterfacePtr.variant_get_ptr_builtin_method(`ty`.variantTypeId, addr gdFuncName, `hash`)
        finally:
          destroyStringName gdFuncName

      var argPtrs: array[`argc`, GDExtensionConstTypePtr] = `args`

      p(
        cast[GDExtensionTypePtr](`selfPtr`),
        cast[ptr GDExtensionConstTypePtr](addr argPtrs),
        cast[GDExtensionTypePtr](`resultPtr`),
        cint(`argc`))
  else:
    let varArgId = varArgs.unsafeGet()[0]

    result[^1] = quote do:
      var p {.global.} = block:
        var gdFuncName = `functionName`.toGodotStringName()

        try:
          gdInterfacePtr.variant_get_ptr_builtin_method(`ty`.variantTypeId, addr gdFuncName, `hash`)
        finally:
          destroyStringName gdFuncName

      var argPtrs = @`args`

      for i in 0..high(`varArgId`):
        argPtrs &= pointer(unsafeAddr `varArgId`[i])

      p(
        cast[GDExtensionTypePtr](`resultPtr`),
        cast[ptr GDExtensionConstTypePtr](addr argPtrs[0]),
        cint(`argc` + len(`varArgId`)))

macro gd_class_method*(hash: static[int64]; prototype: untyped) =
  var argc: int

  let selfPtr = prototype.getSelfPtr(false)
  let selfType = prototype.getSelfType().strVal()
  let resultPtr = prototype.getFuncResultPtr()
  let args = prototype.genArgsList(addr argc, true)
  let varArgs = prototype.getVarArgs()

  let methodName = prototype.getNameFromProto()

  # Varargs-Call (convert all params to Variant and go)
  # object_method_bind_call(
  #   GDExtensionMethodBindPtr p_method_bind,
  #   GDExtensionObjectPtr p_instance,
  #   const GDExtensionConstVariantPtr *p_args,
  #   GDExtensionInt p_arg_count,
  #   GDExtensionVariantPtr r_ret,
  #   GDExtensionCallError *r_error
  #
  # Normal method call
  # object_method_bind_ptrcall(
  #   GDExtensionMethodBindPtr p_method_bind,
  #   GDExtensionObjectPtr p_instance,
  #   const GDExtensionConstTypePtr *p_args,
  #   GDExtensionTypePtr r_ret);

  result = prototype

  if varArgs.isNone():
    result[^1] = quote do:
      var p {.global.} = block:
        var gdClassName = `selfType`.toGodotStringName()
        var gdMethName = `methodName`.toGodotStringName()

        # defer and try-finally result in bad codegen here
        let r = gdInterfacePtr.classdb_get_method_bind(addr gdClassName, addr gdMethName, `hash`)

        destroyStringName gdMethName
        destroyStringName gdClassName

        r

      var argPtrs: array[`argc`, GDExtensionConstTypePtr] = `args`

      gdInterfacePtr.object_method_bind_ptrcall(
        p,
        cast[GDExtensionObjectPtr](`selfPtr`),
        cast[ptr GDExtensionConstTypePtr](addr argPtrs),
        cast[GDExtensionTypePtr](`resultPtr`))

  else:
    result[^1] = quote do:
      discard

  #echo selfPtr.repr()
  if methodName == "get_files" or methodName == "open":
    echo result.repr()

macro gd_builtin_get*(ty: typed; prototype: untyped) =
  let propertyName = prototype.getNameFromProto()

  let selfPtr = prototype.getSelfPtr()
  let resultPtr = prototype.getFuncResultPtr()

  result = prototype
  result[^1] = quote do:
    var p {.global.} = block:
      var gdFuncName = `propertyName`.toGodotStringName()

      try:
        gdInterfacePtr.variant_get_ptr_getter(`ty`.variantTypeId, addr gdFuncName)
      finally:
        destroyStringName gdFuncName

    p(
      cast[GDExtensionConstTypePtr](`selfPtr`),
      cast[GDExtensionTypePtr](`resultPtr`))

macro gd_builtin_set*(ty: typed; prototype: untyped) =
  let propertyName = prototype[0][1][0].strVal()

  let selfPtr = prototype.getSelfPtr()
  let valPtr = prototype[3][2][0]

  result = prototype
  result[^1] = quote do:
    var p {.global.} = block:
      var gdFuncName = `propertyName`.toGodotStringName()

      try:
        gdInterfacePtr.variant_get_ptr_setter(`ty`.variantTypeId, addr gdFuncName)
      finally:
        destroyStringName gdFuncName

    p(
      cast[GDExtensionTypePtr](`selfPtr`),
      cast[GDExtensionConstTypePtr](unsafeAddr `valPtr`))

func isKeyedIndex(node: NimNode): bool =
  node[3][2][^2].strVal == "Variant"

func indexParams(proto: NimNode; setter: bool; fn, idxType, idxNode: ptr NimNode) =
  let idx = proto[3][2][0]

  if proto.isKeyedIndex():
    fn[] = (if setter: "variant_get_ptr_keyed_setter" else: "variant_get_ptr_keyed_getter").ident()
    idxType[] = "GDExtensionConstTypePtr".bindSym()
    idxNode[] = newCall("unsafeAddr".ident(), idx)
  else:
    fn[] = (if setter: "variant_get_ptr_indexed_setter" else: "variant_get_ptr_indexed_getter").ident()
    idxType[] = "GDExtensionInt".bindSym()
    idxNode[] = idx


macro gd_builtin_index_get*(ty: typed; prototype: untyped) =
  var fn: NimNode
  var idxType: NimNode
  var idxNode: NimNode

  prototype.indexParams(false, addr fn, addr idxType, addr idxNode)

  let selfPtr = prototype.getSelfPtr()
  let resultPtr = prototype.getFuncResultPtr()

  result = prototype
  result[^1] = quote do:
    var p {.global.} = gdInterfacePtr.`fn`(`ty`.variantTypeId)

    p(
      cast[GDExtensionConstTypePtr](`selfPtr`),
      cast[`idxType`](`idxNode`),
      cast[GDExtensionTypePtr](`resultPtr`))

macro gd_builtin_index_set*(ty: typed; prototype: untyped) =
  var fn: NimNode
  var idxType: NimNode
  var idxNode: NimNode

  prototype.indexParams(true, addr fn, addr idxType, addr idxNode)

  let selfPtr = prototype.getSelfPtr()
  let valId = prototype[3][^1][^3]

  result = prototype
  result[^1] = quote do:
    var p {.global.} = gdInterfacePtr.`fn`(`ty`.variantTypeId)

    p(
      cast[GDExtensionConstTypePtr](`selfPtr`),
      cast[`idxType`](`idxNode`),
      cast[GDExtensionConstTypePtr](unsafeAddr `valId`))

func toOperatorId(oper: string; unary: bool): GDExtensionVariantOperator =
  case oper
    of "==": result = GDEXTENSION_VARIANT_OP_EQUAL
    of "!=": result = GDEXTENSION_VARIANT_OP_NOT_EQUAL
    of "<": result = GDEXTENSION_VARIANT_OP_LESS
    of "<=": result = GDEXTENSION_VARIANT_OP_LESS_EQUAL
    of ">": result = GDEXTENSION_VARIANT_OP_GREATER
    of ">=": result = GDEXTENSION_VARIANT_OP_GREATER_EQUAL
    of "+": result = if not unary: GDEXTENSION_VARIANT_OP_ADD else: GDEXTENSION_VARIANT_OP_POSITIVE
    of "-": result = if not unary: GDEXTENSION_VARIANT_OP_SUBTRACT else: GDEXTENSION_VARIANT_OP_NEGATE
    of "*": result = GDEXTENSION_VARIANT_OP_MULTIPLY
    of "/": result = GDEXTENSION_VARIANT_OP_DIVIDE
    of "%": result = GDEXTENSION_VARIANT_OP_MODULE
    of "**": result = GDEXTENSION_VARIANT_OP_POWER
    of "<<": result = GDEXTENSION_VARIANT_OP_SHIFT_LEFT
    of ">>": result = GDEXTENSION_VARIANT_OP_SHIFT_RIGHT
    of "&": result = GDEXTENSION_VARIANT_OP_BIT_AND
    of "|": result = GDEXTENSION_VARIANT_OP_BIT_OR
    of "^": result = GDEXTENSION_VARIANT_OP_BIT_XOR
    of "~": result = GDEXTENSION_VARIANT_OP_BIT_NEGATE
    of "and": result = GDEXTENSION_VARIANT_OP_AND
    of "or": result = GDEXTENSION_VARIANT_OP_OR
    of "xor": result = GDEXTENSION_VARIANT_OP_XOR
    of "not": result = GDEXTENSION_VARIANT_OP_NOT
    of "in": result = GDEXTENSION_VARIANT_OP_IN
    else:
      debugEcho "Unknown operator " & oper
      assert false

macro gd_builtin_operator*(ty: typed; prototype: untyped) =
  let isUnary = len(prototype[3]) < 3 and len(prototype[3][1]) < 4

  let lhsPtr = newCall("unsafeAddr".ident(), prototype[3][1][0])
  let lhsTyp = prototype[3][1][^2]

  var rhsPtr = newNilLit()
  var rhsTyp = "Variant".bindSym()

  if not isUnary:
    rhsPtr = newCall("unsafeAddr".ident(), prototype[3][^1][^3])
    rhsTyp = prototype[3][^1][^2]

  let rawOperatorName = prototype[0][1][0].strVal()
  let operatorId = rawOperatorName.toOperatorId(isUnary)

  result = prototype
  result[^1] = quote do:
    var p {.global.} = gdInterfacePtr.variant_get_ptr_operator_evaluator(
        cast[GDExtensionVariantOperator](`operatorId`),
        `lhsTyp`.variantTypeId,
        `rhsTyp`.variantTypeId)

    p(`lhsPtr`, `rhsPtr`, addr result)

proc gd_constant*[K, T](name: static[string]): T =
  var gdName = toGodotStringName(name)
  var resVariant: Variant

  gdInterfacePtr.variant_get_constant_value(
    cast[GDExtensionVariantType](T.variantTypeId),
    addr gdName,
    addr resVariant)

  destroyStringName gdName

  resVariant.castTo(K)