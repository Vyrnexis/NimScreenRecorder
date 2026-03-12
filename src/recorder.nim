import os
import osproc
import streams
import strutils

import ffmpeg
import state
import webcam

# Thin wrapper around the FFmpeg process used for live recordings.

type
  Recorder* = ref object
    process: Process
    webcamController: WebcamController
    currentOutput*: string

proc newRecorder*(): Recorder =
  Recorder(webcamController: newWebcamController())

proc clearExited(process: var Process) =
  if process.isNil:
    return

  if not process.running():
    process.close()
    process = nil

proc stopProcess(process: var Process, gracefulStop: proc() = nil, timeoutMs = 1000) =
  if process.isNil:
    return

  if process.running() and gracefulStop != nil:
    try:
      gracefulStop()
      discard process.waitForExit(timeoutMs)
    except CatchableError:
      discard

  if process.running():
    process.terminate()
    discard process.waitForExit(timeoutMs)

  process.close()
  process = nil

proc clearExitedProcess(recorder: Recorder) =
  # Fold finished processes back to nil so the UI can treat "stopped" consistently.
  if recorder.isNil:
    return

  recorder.process.clearExited()
  recorder.webcamController.clearExited()

proc isRunning*(recorder: Recorder): bool =
  recorder.clearExitedProcess()
  not recorder.isNil and not recorder.process.isNil

proc startRecording*(recorder: Recorder, state: RecorderState): string =
  # Validate before launch so ffmpeg failures are reserved for real runtime issues.
  if recorder.isRunning():
    raise newException(IOError, "Recording is already in progress.")

  let issues = state.validateForRecording()
  if issues.len > 0:
    raise newException(IOError, issues.join("\n"))

  state.outputDir = resolvedOutputDir(state.outputDir)
  createDir(state.outputDir)
  let outputPath = state.buildOutputFilePath()
  let args = state.buildRecordingArgs(outputPath)

  recorder.process = startProcess(
    "ffmpeg",
    args = args,
    options = {poUsePath, poStdErrToStdOut}
  )
  recorder.currentOutput = outputPath
  outputPath

proc stopRecording*(recorder: Recorder) =
  # Ask ffmpeg to stop cleanly first so MP4 metadata is finalized.
  if recorder.isNil or recorder.process.isNil:
    return

  recorder.process.stopProcess(
    gracefulStop = proc() =
      let input = recorder.process.inputStream()
      input.write("q\n")
      input.flush()
    ,
    timeoutMs = 5000
  )

proc showWebcamWindow*(recorder: Recorder, state: RecorderState) =
  if recorder.isNil:
    return
  recorder.webcamController.show(state)

proc hideWebcamWindow*(recorder: Recorder) =
  if recorder.isNil:
    return

  recorder.webcamController.hide()
