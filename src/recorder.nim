import os
import osproc
import streams

import ffmpeg_builder
import state

type
  Recorder* = ref object
    process: Process
    currentOutput*: string

proc newRecorder*(): Recorder =
  Recorder()

proc clearExitedProcess(recorder: Recorder) =
  if recorder.isNil or recorder.process.isNil:
    return

  if not recorder.process.running():
    recorder.process.close()
    recorder.process = nil

proc isRunning*(recorder: Recorder): bool =
  recorder.clearExitedProcess()
  not recorder.isNil and not recorder.process.isNil

proc startRecording*(recorder: Recorder, state: RecorderState): string =
  if recorder.isRunning():
    raise newException(IOError, "Recording is already in progress.")

  createDir(state.outputDir)
  let outputPath = state.buildOutputFilePath()
  let args = state.buildRecordingArgs(outputPath)

  recorder.process = startProcess(
    "ffmpeg",
    args = args,
    options = {poUsePath, poStdErrToStdOut}
  )
  recorder.currentOutput = outputPath
  state.isRecording = true
  outputPath

proc stopRecording*(recorder: Recorder, state: RecorderState) =
  if recorder.isNil or recorder.process.isNil:
    state.isRecording = false
    return

  if recorder.process.running():
    try:
      let input = recorder.process.inputStream()
      input.write("q\n")
      input.flush()
      discard recorder.process.waitForExit(5000)
    except CatchableError:
      discard

  if recorder.process.running():
    recorder.process.terminate()
    discard recorder.process.waitForExit(2000)

  recorder.process.close()
  recorder.process = nil
  state.isRecording = false
