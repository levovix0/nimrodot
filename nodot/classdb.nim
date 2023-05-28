import ../nodot
import ./builtins/types/[variant, stringname]
import ./enums

import std/[macros, genasts, tables, strutils, options]

type
  ClassRegistration = object
    typeNode: NimNode
    parentNode: NimNode

    ctorFuncIdent: NimNode
    dtorFuncIdent: NimNode

    properties: OrderedTable[string, ClassProperty]
    methods: OrderedTable[string, MethodInfo]

  ClassProperty = object
    setter: NimNode
    getter: NimNode

  MethodInfo = object
    symbol: NimNode

var classes* {.compileTime.} = initOrderedTable[string, ClassRegistration]()

macro custom_class*(def: untyped): untyped =
  def[0].expectKind(nnkPragmaExpr)
  def[0][0].expectKind(nnkIdent)

  def[2].expectKind(nnkObjectTy)

  # Unless specified otherwise, we derive from Godot's "Object"
  if def[2][1].kind == nnkEmpty:
    def[2][1] = newTree(nnkOfInherit, "Object".ident())

  classes[def[0][0].strVal()] = ClassRegistration(
    typeNode: def[0][0],
    parentNode: def[2][1][0])

  if def[2][1][0].strVal() notin classes:
    # If we are deriving from a Godot class as opposed to one of our own,
    # we add in a field to store our runtime class information into.
    def[2][2] &= newIdentDefs("gdclassinfo".ident(), "pointer".ident())

  def

macro ctor*(def: typed) =
  def.expectKind(nnkProcDef)

  def[3][1][^2].expectKind(nnkVarTy)
  def[3][1][^2][0].expectKind(nnkSym)

  classes[def[3][1][^2][0].strVal()].ctorFuncIdent = def[0]

  def

macro dtor*(def: typed) =
  def.expectKind(nnkProcDef)

  def[3][1][^2].expectKind(nnkVarTy)
  def[3][1][^2][0].expectKind(nnkSym)

  classes[def[3][1][^2][0].strVal()].dtorFuncIdent = def[0]

  def

macro classMethod*(def: typed) =
  def.expectKind(nnkProcDef)

  def[3][1][^2].expectKind(nnkVarTy)
  def[3][1][^2][0].expectKind(nnkSym)

  # TODO: Capture default arguments here, as they are lost below
  classes[def[3][1][^2][0].strVal()].methods[def[0].strVal()] = MethodInfo(
    symbol: def[0]
  )

  def

macro property*(def: typed) =
  def.expectKind(nnkProcDef)

  def[0].expectKind(nnkSym)

  let isSetter = def[0].strVal().endsWith('=')

  if isSetter:
    # Property setter function
    def[3][0].expectKind(nnkEmpty)
    def[3][1][1].expectKind(nnkVarTy)

    def[3][2][1].expectIdent("Variant") # for now

  else:
    # Property getter function
    def[3][0].expectKind(nnkSym)
    def[3][0].expectIdent("Variant") # for now
    def[3][1][1].expectKind(nnkVarTy)

  let classType = def[3][1][1][0]
  let propertyName = if isSetter: def[0].strVal()[0..^2] else: def[0].strVal()

  var p = classes[classType.strVal()].properties.mgetOrPut(propertyName, default(ClassProperty))

  if isSetter:
    p.setter = def[0]
  else:
    p.getter = def[0]

  def

func typeMetaData(_: typedesc): auto = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE

func propertyHint(_: typedesc): auto = phiNone
func propertyUsage(_: typedesc): auto = pufDefault

func typeMetaData(_: typedesc[int | uint]): auto =
  if (sizeOf int) == 4:
    GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT32
  else:
    GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT64

func typeMetaData(_: typedesc[int8]): auto = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT8
func typeMetaData(_: typedesc[int16]): auto = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT16
func typeMetaData(_: typedesc[int32]): auto = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT32
func typeMetaData(_: typedesc[int64]): auto = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT64

func typeMetaData(_: typedesc[uint8]): auto = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_UINT8
func typeMetaData(_: typedesc[uint16]): auto = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_UINT16
func typeMetaData(_: typedesc[uint32]): auto = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_UINT32
func typeMetaData(_: typedesc[uint64]): auto = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_UINT64

func typeMetaData(_: typedesc[float32]): auto = GDEXTENSION_METHOD_ARGUMENT_METADATA_REAL_IS_FLOAT
func typeMetaData(_: typedesc[float64 | float]): auto = GDEXTENSION_METHOD_ARGUMENT_METADATA_REAL_IS_DOUBLE


proc create_callback(token, instance: pointer): pointer {.cdecl.} = nil
proc free_callback(token, instance, binding: pointer) {.cdecl.} = discard
proc reference_callback(token, instance: pointer; reference: GDExtensionBool): GDExtensionBool {.cdecl.} = 1

var nopOpBinding = GDExtensionInstanceBindingCallbacks(
  create_callback: create_callback,
  free_callback: free_callback,
  reference_callback: reference_callback)

type
  ConstructorFunc[T] = proc(obj: var T)
  DestructorFunc[T] = proc(obj: var T)

  #PropertyGetterFunc[T] = proc(obj: var T): Variant
  #PropertySetterFunc[T] = proc(obj: var T; value: Variant)

  RuntimeClassRegistration[T] = object
    lastGodotAncestor: StringName = "Object"

    ctor: ConstructorFunc[T]
    dtor: DestructorFunc[T]


proc create_instance[T, P](userdata: pointer): pointer {.cdecl.} =
  var nimInst = cast[ptr T](gdInterfacePtr.mem_alloc(sizeof(T).csize_t))
  var rcr = cast[ptr RuntimeClassRegistration[T]](userdata)

  var className = ($T).StringName
  var lastNativeClassName = rcr.lastGodotAncestor
  var parentClassName = ($P).StringName

  # We construct the parent class and store it into our opaque pointer field, so we have
  # a handle from Godot, for Godot.
  nimInst.opaque = gdInterfacePtr.classdb_construct_object(addr lastNativeClassName)
  nimInst.gdclassinfo = userdata

  rcr.ctor(nimInst[])

  # We tell Godot what the actual type for our object is and bind our native class to
  # its native class.
  gdInterfacePtr.object_set_instance(nimInst.opaque, addr className, nimInst)
  gdInterfacePtr.object_set_instance_binding(nimInst.opaque, gdTokenPtr, nimInst, addr nopOpBinding)

  nimInst.opaque

proc free_instance[T, P](userdata: pointer; instance: GDExtensionClassInstancePtr) {.cdecl.} =
  var nimInst = cast[ptr T](instance)
  var rcr = cast[ptr RuntimeClassRegistration[T]](userdata)

  rcr.dtor(nimInst[])

  gdInterfacePtr.mem_free(nimInst)

proc instance_to_string[T](instance: GDExtensionClassInstancePtr;
                  valid: ptr GDExtensionBool;
                  str: GDExtensionStringPtr) {.cdecl.} =
  var nimInst = cast[ptr T](instance)

  when compiles($nimInst[]):
    gdInterfacePtr.string_new_with_utf8_chars(str, cstring($nimInst[]))
    valid[] = 1
  else:
    valid[] = 0

proc registerClass*[T, P](
    lastNative: StringName,
    ctorFunc: proc(x: var T);
    dtorFunc: proc(x: var T)) =
  var className: StringName = $T
  var parentClassName: StringName = $P

  # Needs static lifetime, so {.global.}
  var rcr {.global.}: RuntimeClassRegistration[T] = RuntimeClassRegistration[T](
    ctor: ctorFunc,
    dtor: dtorFunc,
    lastGodotAncestor: lastNative
  )

  var creationInfo = GDExtensionClassCreationInfo(
    is_virtual: 0,  # TODO
    is_abstract: 0, # TODO

    set_func: nil, #property_set[T],
    get_func: nil, #property_get[T],

    get_property_list_func: nil, #list_properties[T],
    free_property_list_func: nil, #free_properties[T],

    property_can_revert_func: nil, #can_property_revert[T],
    property_get_revert_func: nil, #property_revert[T],

    notification_func: nil, #notify[T],
    to_string_func: instance_to_string[T],
    reference_func: nil,
    unreference_func: nil,

    create_instance_func: create_instance[T, P], # default ctor
    free_instance_func: free_instance[T, P],     # dtor
    get_virtual_func: nil,
    get_rid_func: nil,

    class_userdata: addr rcr)

  gdInterfacePtr.classdb_register_extension_class(
    gdTokenPtr,
    addr className,
    addr parentClassName,
    addr creationInfo)

type
  ReturnValueInfo = tuple
    returnValue: GDExtensionPropertyInfo
    returnMeta: GDExtensionClassMethodArgumentMetadata

# Since we deal with a lot of compile time know stuff, this comes in
# useful quite often. As the function is generated once per string,
# we have our own interning of interned strings.
proc staticStringName(s: static[string]): ptr StringName =
  var interned {.global.}: StringName = s

  addr interned

proc gdClassName(_: typedesc): ptr StringName = staticStringName("")


macro getReturnInfo(m: typed): Option[ReturnValueInfo] =
  let typeInfo = m.getTypeInst()

  if typeInfo[0][0].kind == nnkEmpty:
    return genAst: none ReturnValueInfo

  return genAst(R = typeInfo[0][0].getType()):
    some (
      returnValue: GDExtensionPropertyInfo(
        `type`: variantTypeId(typeOf R),
        name: staticStringName(""),
        class_name: gdClassName(typeOf R),
        hint: uint32(propertyHint(typeOf R)),
        hint_string: staticStringName(""),
        usage: uint32(propertyUsage(typeOf R))
      ),
      returnMeta: typeMetaData(typeOf R))

macro getMethodFlags(m: typed): static[set[GDExtensionClassMethodFlags]] =
  # TODO
  genAst:
    {GDEXTENSION_METHOD_FLAGS_DEFAULT}

macro getArity(m: typed): static[int] =
  let typedM = m.getTypeInst()

  var argc = 0

  if len(typedM[0]) > 2:
    for defs in typedM[0][2..^1]:
      for binding in defs[0..^3]:
        inc argc

  newLit(argc)

macro getParameterInfo(m: typed): auto =
  let typedM = m.getTypeInst()

  var args = newTree(nnkBracket)

  # TODO:
  #   - Get default values from global "classes"
  #   - Retrieve a hint name somehow. Parse doc comment if applied, or {.hint.} pragma?

  # we ignore the first parameter, as it's implied for Godot
  if len(typedM[0]) > 2:
    for defs in typedM[0][2..^1]:
      for binding in defs[0..^3]:
        let arg = genAst(n = binding.strVal(), P = defs[^2]):
          GDExtensionPropertyInfo(
           `type`: variantTypeId(typeOf P),
            name: staticStringName(n),
            class_name: gdClassName(typeOf P),
            hint: uint32(propertyHint(typeOf P)),
            hint_string: staticStringName(""),
            usage: uint32(propertyUsage(typeOf P))
          )

        args &= arg

  genAst(args):
    args

macro getParameterMetaInfo(m: typed): auto =
  let typedM = m.getTypeInst()

  var args = newTree(nnkBracket)

  # TODO: Get default values from global "classes"

  # we ignore the first parameter, as it's implied for godot
  if len(typedM[0]) > 2:
    for defs in typedM[0][2..^1]:
      for binding in defs[0..^3]:
        let arg = genAst(P = defs[^2]):
          typeMetaData(typeOf P)

        args &= arg

  genAst(args):
    args

proc registerMethod[T, M: proc](name: string; callable: static[M]) =
  var className: StringName = $T
  var methodName: StringName = name

  var returnInfo = callable.getReturnInfo()
  var rvInfo: ptr GDExtensionPropertyInfo = nil
  var rvMeta = GDEXTENSION_METHOD_ARGUMENT_METADATA_NONE

  if returnInfo.isSome():
    rvInfo = addr returnInfo.unsafeGet().returnValue
    rvMeta = returnInfo.unsafeGet().returnMeta

  const argc = static callable.getArity()

  var args: array[argc, GDExtensionPropertyInfo] =
    callable.getParameterInfo()

  var argsMeta: array[argc, GDExtensionClassMethodArgumentMetadata] =
    callable.getParameterMetaInfo()

  var methodInfo = GDExtensionClassMethodInfo(
    name: addr methodName,
    method_userdata: nil,

    call_func: nil,
    ptrcall_func: nil,
    method_flags: cast[uint32](callable.getMethodFlags()),

    has_return_value: GDExtensionBool(returnInfo.isSome()),
    return_value_info: rvInfo,
    return_value_metadata: rvMeta,

    argument_count: uint32(argc),
    arguments_info: cast[ptr GDExtensionPropertyInfo](addr args),
    arguments_metadata: cast[ptr GDExtensionClassMethodArgumentMetadata](addr argsMeta),

    default_argument_count: 0,
    default_arguments: nil, # array[default_argument_count, GDExtensionVariantPtr]
  )

  gdInterfacePtr.classdb_register_extension_class_method(
    gdTokenPtr,
    addr className,
    addr methodInfo)

macro register*() =
  result = newStmtList()

  for className, regInfo in classes:
    # Because we (apparently) cannot cleanly derive from our own classes, we establish
    # the latest class that is native to Godot and "derive" from that. The instance is
    # still registered to the correct parent class type, but everything after the
    # last Godot class is handled Nim-side.
    var lastAncestor = regInfo.parentNode.strVal()

    while lastAncestor in classes:
      lastAncestor = classes[lastAncestor].parentNode.strVal()

    let classReg = genAst(
        lastAncestor,
        T = regInfo.typeNode,
        P = regInfo.parentNode,
        ctor = regInfo.ctorFuncIdent,
        dtor = regInfo.dtorFuncIdent):

      registerClass[T, P](lastAncestor, ctor, dtor)

    result.add(classReg)

    for methodName, methodInfo in regInfo.methods:
      let methodType = methodInfo.symbol.getTypeInst()

      let methodReg = genAst(
          T = regInfo.typeNode,
          methodName,
          methodType,
          methodSymbol = methodInfo.symbol):
        registerMethod[T, methodType](methodName, methodSymbol)

      result.add(methodReg)