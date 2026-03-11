import os
import times

import state

proc x11InputTarget*(state: RecorderState, x, y: int): string =
  let display = if state.display.len == 0: ":0.0" else: state.display
  display & "+" & $x & "," & $y

proc buildOutputFilePath*(state: RecorderState): string =
  let timestamp = now().format("yyyy-MM-dd'_'HH-mm-ss")
  let projectName = sanitizedProjectName(state.projectName)
  let fileName =
    if projectName.len == 0:
      timestamp & ".mp4"
    else:
      projectName & "_" & timestamp & ".mp4"
  state.outputDir / fileName

proc buildRecordingArgs*(state: RecorderState, outputPath: string): seq[string] =
  result = @[
    "-y",
    "-hide_banner",
    "-loglevel", "error",
    "-nostats",
    "-f", "x11grab",
    "-video_size", $state.width & "x" & $state.height,
    "-framerate", $state.fps,
    "-i", state.x11InputTarget(state.posX, state.posY)
  ]

  if state.audioSource != NoAudioSource:
    result.add(@["-f", "pulse", "-i", state.audioSource])

  if state.duration > 0:
    result.add(@["-t", $state.duration])

  result.add(@[
    "-c:v", "libx264",
    "-preset", "veryfast",
    "-pix_fmt", "yuv420p",
    "-movflags", "+faststart",
    outputPath
  ])

proc buildSnapshotArgs*(state: RecorderState, outputPath: string): seq[string] =
  @[
    "-y",
    "-hide_banner",
    "-loglevel", "error",
    "-nostats",
    "-nostdin",
    "-f", "x11grab",
    "-video_size", $state.desktopWidth & "x" & $state.desktopHeight,
    "-i", state.x11InputTarget(0, 0),
    "-frames:v", "1",
    outputPath
  ]
