import os

# Package

version       = "0.1.0"
author        = "Vyrnexis"
description   = "A small screen recorder with regional and resolution settings"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @["NimScreenRecorder"]


# Dependencies

requires "nim >= 2.2.0"
requires "nigui >= 0.2.8"

let portableCpuFlags =
  when defined(amd64):
    " --passC:-march=x86-64 --passC:-mtune=generic"
  else:
    ""

task Release, "Build a normal release binary using local compiler defaults":
  mkDir("bin")
  exec "nim c -d:release --out:bin/NimScreenRecorder src/NimScreenRecorder.nim"

task ReleasePortable, "Build a portable release binary into ./bin":
  mkDir("bin")
  exec "nim c -d:release" & portableCpuFlags & " --out:bin/NimScreenRecorder src/NimScreenRecorder.nim"
  
task Debug, "Build a debug binary into ./bin":
  mkDir("bin")
  exec "nim c --out:bin/NimScreenRecorder src/NimScreenRecorder.nim"

