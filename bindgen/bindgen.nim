import std/os

import ./api
import ./helpers

const sourceApiFile = "contrib/extension_api.json"

import filters/files/"api.nimf" as apiFileGen
import filters/files/"utility.nimf" as utilityFileGen
import filters/files/"native_structs.nimf" as nativeStructsFileGen
import filters/files/"enums.nimf" as enumsFileGen
import filters/files/builtins/"all_types.nimf" as builtinAllTypesGen
import filters/files/builtins/"type.nimf" as builtinTypeGen
import filters/files/builtins/"procs.nimf" as builtinProcGen
import filters/files/classes/"type.nimf" as classTypeGen
import filters/files/classes/"procs.nimf" as classProcGen

when nimvm:
  func projectPath(): string = "./bindgen/bindgen.nim"

  proc rmFile(path: string) =
    path.removeFile()

  proc cpFile(source, dest: string) =
    source.copyFile(dest)

  proc mkDir(dirs: string) =
    dirs.createDir()

else:
  discard

when isMainModule:
  echo projectPath()

  let projectRoot = projectPath()
    .parentDir()
    .parentDir()

  let sourceRoot = projectRoot / "nodot"
  let apiFile = sourceApiFile.importApi()

  # Clean previously generated files, if any
  for builtinClass in apiFile.builtin_classes:
    if not builtinClass.isNativeClass():
      rmFile sourceRoot / "builtins" / builtinClass.moduleName() & ".nim"

  cpFile(projectRoot / "contrib/gdextension_interface.nim", sourceRoot  / "ffi.nim")

  helpers.apiDef = apiFile

  writeFile(sourceRoot / "api.nim", apiFileGen.generate())
  writeFile(sourceRoot / "utility_functions.nim", utilityFileGen.generate())
  writeFile(sourceRoot / "enums.nim", enumsFileGen.generate())
  writeFile(sourceRoot / "native_structs.nim", nativeStructsFileGen.generate())

  mkdir sourceRoot / "builtins" / "types"
  mkdir sourceRoot / "classes" / "types"

  writeFile(
    sourceRoot / "builtins" / "types.nim",
    builtinAllTypesGen.generate())

  for builtinClass in apiFile.builtin_classes:
    if not builtinClass.isNativeClass():
      writeFile(
        sourceRoot / "builtins" / "types" / builtinClass.moduleName() & ".nim",
        builtinTypeGen.generate(builtinClass))

      writeFile(
        sourceRoot / "builtins" / builtinClass.moduleName() & ".nim",
        builtinProcGen.generate(builtinClass))

  for class in apiFile.classes:
    writeFile(
      sourceRoot / "classes" / "types" / class.moduleName() & ".nim",
      classTypeGen.generate(class))

    writeFile(
      sourceRoot / "classes" / class.moduleName() & ".nim",
      classProcGen.generate(class))