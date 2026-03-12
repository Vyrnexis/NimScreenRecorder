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

task Debug, "Build a debug binary into ./bin":
  mkDir("bin")
  exec "nim c --nimcache:.nimcache --out:bin/NimScreenRecorder src/NimScreenRecorder.nim"

task Release, "Build a release binary into ./bin":
  mkDir("bin")
  exec "nim c -d:release --nimcache:.nimcache --out:bin/NimScreenRecorder src/NimScreenRecorder.nim"
