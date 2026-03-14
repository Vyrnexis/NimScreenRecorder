import os
import osproc
import sequtils
import streams
import strutils
import times

import ffmpeg
import state
import webcam

# Thin wrapper around the FFmpeg process used for live recordings.

############################
# Recorder State
############################

type
  Recorder* = ref object
    process: Process
    webcamController: WebcamController
    sessionActive: bool
    sessionDir: string
    segmentPaths: seq[string]
    segmentIndex: int
    paused: bool
    currentOutput*: string
    currentLogPath: string
    lastLogPath*: string
    lastExitCode*: int
    lastEndedUnexpectedly*: bool
    lastFailureSummary*: string
    completionSerial*: int
    stopRequested: bool

############################
# Local Helpers
############################

proc newRecorder*(): Recorder =
  Recorder(webcamController: newWebcamController())

proc buildLogPath(outputPath: string): string =
  let file = splitFile(outputPath)
  file.dir / (file.name & ".ffmpeg.log")

proc buildRemuxPath(outputPath: string): string =
  let file = splitFile(outputPath)
  file.dir / (file.name & ".mp4")

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

proc buildSessionDir(): string =
  let timestamp = now().format("yyyyMMdd'_'HHmmss")
  getTempDir() / ("nim_screen_recorder_" & timestamp & "_" & $epochTime().int)

proc escapeConcatPath(path: string): string =
  path.replace("'", "'\\''")

proc cleanupSessionFiles(recorder: Recorder) =
  if recorder.isNil or recorder.sessionDir.len == 0:
    return

  try:
    if dirExists(recorder.sessionDir):
      for file in walkDirRec(recorder.sessionDir):
        try:
          removeFile(file)
        except OSError:
          discard
      try:
        removeDir(recorder.sessionDir)
      except OSError:
        discard
  except OSError:
    discard

proc clearSession(recorder: Recorder) =
  recorder.cleanupSessionFiles()
  recorder.sessionActive = false
  recorder.sessionDir = ""
  recorder.segmentPaths.setLen(0)
  recorder.segmentIndex = 0
  recorder.paused = false

proc stopActiveProcess(recorder: Recorder, timeoutMs = 5000) =
  if recorder.isNil or recorder.process.isNil:
    return

  recorder.stopRequested = true
  recorder.process.stopProcess(
    gracefulStop = proc() =
      let input = recorder.process.inputStream()
      input.write("q\n")
      input.flush()
    ,
    timeoutMs = timeoutMs
  )
  recorder.stopRequested = false

proc runBlockingFfmpeg(args: seq[string]): tuple[exitCode: int, output: string] =
  var process: Process
  try:
    process = startProcess(
      "ffmpeg",
      args = args,
      options = {poUsePath, poStdErrToStdOut}
    )
    result.exitCode = process.waitForExit()
    result.output = process.outputStream.readAll().strip()
  finally:
    if process != nil:
      process.close()

proc writeFailureLog(logPath, output: string) =
  if logPath.len == 0 or output.len == 0:
    return
  try:
    writeFile(logPath, output & "\n")
  except CatchableError:
    discard

proc nextSegmentPath(recorder: Recorder): string =
  recorder.sessionDir / ("segment_" & align($(recorder.segmentIndex + 1), 4, '0') & ".mkv")

############################
# Session Lifecycle
############################

proc startSegment(recorder: Recorder, state: RecorderState) =
  let segmentPath = recorder.nextSegmentPath()
  recorder.process = startProcess(
    "ffmpeg",
    args = state.buildSegmentRecordingArgs(segmentPath),
    options = {poUsePath, poStdErrToStdOut}
  )
  recorder.segmentPaths.add(segmentPath)
  recorder.segmentIndex.inc

proc finalizeRecording(recorder: Recorder, state: RecorderState) =
  if recorder.segmentPaths.len == 0:
    recorder.clearSession()
    return

  let concatListPath = recorder.sessionDir / "segments.txt"
  let concatList = recorder.segmentPaths
    .mapIt("file '" & escapeConcatPath(it) & "'")
    .join("\n") & "\n"
  try:
    writeFile(concatListPath, concatList)
  except CatchableError:
    recorder.lastExitCode = -1
    recorder.lastEndedUnexpectedly = true
    recorder.lastFailureSummary = "Could not write the recording segment list."
    recorder.completionSerial.inc
    recorder.clearSession()
    return

  let (exitCode, output) = runBlockingFfmpeg(
    buildConcatArgs(concatListPath, recorder.currentOutput, state.outputFormat)
  )
  recorder.lastExitCode = exitCode
  recorder.lastLogPath = recorder.currentLogPath
  recorder.lastEndedUnexpectedly = exitCode != 0
  recorder.lastFailureSummary =
    if output.len > 0:
      output.splitLines()[0].strip()
    else:
      ""
  if exitCode != 0:
    writeFailureLog(recorder.currentLogPath, output)
    recorder.completionSerial.inc
  elif state.outputFormat == OutputFormatMkv and state.remuxToMp4:
    let remuxPath = buildRemuxPath(recorder.currentOutput)
    let (remuxExitCode, remuxOutput) = runBlockingFfmpeg(
      buildRemuxArgs(recorder.currentOutput, remuxPath)
    )
    recorder.lastExitCode = remuxExitCode
    if remuxExitCode != 0:
      recorder.lastEndedUnexpectedly = true
      recorder.lastFailureSummary =
        if remuxOutput.len > 0:
          remuxOutput.splitLines()[0].strip()
        else:
          "Failed to remux recording to MP4."
      writeFailureLog(recorder.currentLogPath, remuxOutput)
      recorder.completionSerial.inc
    else:
      recorder.currentOutput = remuxPath

  if exitCode == 0:
    state.pushRecentRecording(recorder.currentOutput)
  recorder.clearSession()
  recorder.currentLogPath = ""

proc clearExitedProcess(recorder: Recorder) =
  # Fold finished processes back to nil so the UI can treat "stopped" consistently.
  if recorder.isNil:
    return

  if recorder.process != nil and not recorder.process.running():
    let exitCode =
      try:
        recorder.process.waitForExit()
      except OSError:
        -1

    let output =
      try:
        recorder.process.outputStream.readAll().strip()
      except CatchableError:
        ""

    recorder.lastExitCode = exitCode
    recorder.lastLogPath = recorder.currentLogPath
    recorder.lastEndedUnexpectedly = not recorder.stopRequested and exitCode != 0
    recorder.lastFailureSummary =
      if output.len > 0:
        output.splitLines()[0].strip()
      else:
        ""
    if recorder.currentLogPath.len > 0 and (output.len > 0 or exitCode != 0):
      writeFailureLog(recorder.currentLogPath, output)
    recorder.completionSerial.inc
    recorder.clearSession()
    recorder.currentLogPath = ""
    recorder.stopRequested = false
    recorder.process.close()
    recorder.process = nil

  recorder.webcamController.clearExited()

############################
# Public API
############################

proc isRunning*(recorder: Recorder): bool =
  recorder.clearExitedProcess()
  not recorder.isNil and recorder.sessionActive

proc isPaused*(recorder: Recorder): bool =
  recorder.isRunning() and recorder.paused and recorder.process.isNil

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
  recorder.clearSession()
  recorder.sessionDir = buildSessionDir()
  createDir(recorder.sessionDir)
  recorder.sessionActive = true
  recorder.segmentPaths = @[]
  recorder.segmentIndex = 0
  recorder.stopRequested = false
  recorder.paused = false
  recorder.lastEndedUnexpectedly = false
  recorder.lastFailureSummary = ""
  recorder.lastExitCode = 0
  recorder.currentLogPath = buildLogPath(outputPath)
  recorder.currentOutput = outputPath
  try:
    recorder.startSegment(state)
  except CatchableError:
    recorder.clearSession()
    recorder.currentLogPath = ""
    raise
  outputPath

proc pauseRecording*(recorder: Recorder) =
  # Pausing closes the current segment so the final output can skip paused time.
  if recorder.isNil or recorder.process.isNil or recorder.paused or not recorder.sessionActive:
    return

  recorder.stopActiveProcess()
  recorder.paused = true

proc resumeRecording*(recorder: Recorder, state: RecorderState) =
  # Resuming starts a fresh segment that will be concatenated at final stop.
  if recorder.isNil or not recorder.paused or not recorder.sessionActive or recorder.process != nil:
    return

  recorder.startSegment(state)
  recorder.paused = false

proc stopRecording*(recorder: Recorder, state: RecorderState) =
  # Stop the active segment, then assemble the final output from all kept segments.
  if recorder.isNil or not recorder.sessionActive:
    return

  if recorder.process != nil:
    recorder.stopActiveProcess()

  recorder.finalizeRecording(state)

proc showWebcamWindow*(recorder: Recorder, state: RecorderState) =
  if recorder.isNil:
    return
  recorder.webcamController.show(state)

proc hideWebcamWindow*(recorder: Recorder) =
  if recorder.isNil:
    return

  recorder.webcamController.hide()
