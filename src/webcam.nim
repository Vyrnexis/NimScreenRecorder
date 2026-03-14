import algorithm
import os
import osproc
import strutils

import state

# Webcam window support stays in one module now that ffplay is the only backend.

type
  WebcamController* = ref object
    process: Process

proc hide*(controller: WebcamController)

proc detectWebcamDevices*(): seq[string] =
  # Webcam input is optional, so keep the dropdown usable even when no camera is attached.
  if dirExists("/dev"):
    for _, path in walkDir("/dev", relative = false):
      let name = extractFilename(path)
      if name.startsWith("video") and path notin result:
        result.add(path)

  result.sort()
  if result.len == 0:
    result = @[NoWebcamDevice]

proc hasWebcamDevice*(device: string): bool =
  device.len > 0 and device != NoWebcamDevice

proc webcamWindowSize(state: RecorderState): tuple[width, height: int] =
  # Keep the webcam window sizes consistent with the UI presets.
  case state.webcamSize
  of WebcamSizeSmall:
    (320, 240)
  of WebcamSizeLarge:
    (640, 480)
  else:
    (480, 360)

proc webcamWindowPosition(state: RecorderState): tuple[x, y: int] =
  let size = state.webcamWindowSize()
  let margin = max(0, state.webcamMargin)
  let rightInset = max(0, state.width - size.width - margin)
  let bottomInset = max(0, state.height - size.height - margin)
  case state.webcamPosition
  of WebcamPositionTopLeft:
    (state.posX + margin, state.posY + margin)
  of WebcamPositionTopRight:
    (state.posX + rightInset, state.posY + margin)
  of WebcamPositionBottomLeft:
    (state.posX + margin, state.posY + bottomInset)
  else:
    (
      state.posX + rightInset,
      state.posY + bottomInset
    )

proc webcamViewerFramerate(state: RecorderState): int =
  # Keep ffplay responsive without requesting unrealistic webcam frame rates.
  min(max(state.fps, 1), 30)

proc clearExitedProcess(process: var Process) =
  if process.isNil:
    return
  if not process.running():
    process.close()
    process = nil

proc stopProcess(process: var Process, timeoutMs = 1000) =
  if process.isNil:
    return
  if process.running():
    process.terminate()
    discard process.waitForExit(timeoutMs)
  process.close()
  process = nil

proc buildViewerArgs(state: RecorderState): seq[string] =
  let size = state.webcamWindowSize()
  let position = state.webcamWindowPosition()
  result = @[
    "-hide_banner",
    "-loglevel", "error",
    "-window_title", "Nim Screen Recorder Webcam",
    "-noborder",
    "-alwaysontop",
    "-fflags", "nobuffer",
    "-flags", "low_delay",
    "-framedrop",
    "-an",
    "-x", $size.width,
    "-y", $size.height,
    "-left", $position.x,
    "-top", $position.y,
    "-f", "v4l2",
    "-framerate", $state.webcamViewerFramerate()
  ]
  if state.webcamMirror:
    result.add(@["-vf", "hflip"])
  result.add(@["-i", state.webcamDevice])

proc newWebcamController*(): WebcamController =
  WebcamController()

proc clearExited*(controller: WebcamController) =
  if controller.isNil:
    return
  controller.process.clearExitedProcess()

proc show*(controller: WebcamController, state: RecorderState) =
  if controller.isNil:
    return
  if not hasWebcamDevice(state.webcamDevice):
    raise newException(IOError, "Select a webcam device first.")
  if findExe("ffplay").len == 0:
    raise newException(IOError, "ffplay is not installed or not on PATH.")
  if not pathReadable(state.webcamDevice):
    raise newException(IOError, "Selected webcam device was not found: " & state.webcamDevice)

  controller.hide()
  controller.process = startProcess(
    "ffplay",
    args = state.buildViewerArgs(),
    options = {poUsePath, poStdErrToStdOut}
  )

proc hide*(controller: WebcamController) =
  if controller.isNil:
    return
  controller.process.stopProcess(timeoutMs = 1000)
