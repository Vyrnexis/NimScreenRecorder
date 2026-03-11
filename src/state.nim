import os
import osproc
import strutils

const
  PresetFullScreen* = "Full Screen"
  PresetCustom* = "Custom"
  NoAudioSource* = "None"
  DefaultAudioSource* = "default"

  ResolutionPresetOptions* = @[
    PresetFullScreen,
    "3840x2160",
    "2560x1440",
    "1920x1080",
    "1280x720",
    "1080x1920 Shorts",
    PresetCustom
  ]

  FpsOptions* = @["24", "30", "60"]

type
  RecorderState* = ref object
    projectName*: string
    outputDir*: string
    width*: int
    height*: int
    posX*: int
    posY*: int
    fps*: int
    duration*: int
    preset*: string
    audioSource*: string
    isRecording*: bool
    display*: string
    desktopWidth*: int
    desktopHeight*: int

proc clampInt(value, minValue, maxValue: int): int =
  if value < minValue:
    return minValue
  if value > maxValue:
    return maxValue
  value

proc sanitizedProjectName*(projectName: string): string =
  let source = projectName.strip()
  for ch in source:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}:
      result.add(ch)
    elif ch == ' ':
      result.add('_')
    else:
      result.add('_')

  result = result.strip(chars = {'_'})

proc defaultOutputDir*(projectName: string): string =
  let videosDir = getHomeDir() / "Videos"
  let projectDir = sanitizedProjectName(projectName)
  if projectDir.len == 0:
    return videosDir
  videosDir / projectDir

proc tryParseResolutionToken(token: string): tuple[ok: bool, width, height: int] =
  let normalized = token.strip()
  if 'x' notin normalized:
    return (false, 0, 0)
  let parts = normalized.split('x')
  if parts.len != 2:
    return (false, 0, 0)
  try:
    result = (true, parts[0].parseInt(), parts[1].parseInt())
  except ValueError:
    result = (false, 0, 0)

proc detectDesktopSize*(): tuple[width, height: int] =
  let attempts = [execCmdEx("xdpyinfo"), execCmdEx("xrandr --current")]

  for (output, exitCode) in attempts:
    if exitCode != 0:
      continue

    for line in output.splitLines():
      if "dimensions:" in line:
        for token in line.splitWhitespace():
          let parsed = tryParseResolutionToken(token)
          if parsed.ok:
            return (parsed.width, parsed.height)

      if " current " in line:
        let currentIndex = line.find(" current ")
        if currentIndex >= 0:
          let remainder = line[currentIndex + " current ".len .. ^1]
          let chunk = remainder.split(",", maxsplit = 1)[0]
          let pieces = chunk.splitWhitespace()
          if pieces.len >= 3 and pieces[1] == "x":
            try:
              return (pieces[0].parseInt(), pieces[2].parseInt())
            except ValueError:
              discard

  (1920, 1080)

proc detectAudioSources*(): seq[string] =
  result = @[NoAudioSource, DefaultAudioSource]
  let (output, exitCode) = execCmdEx("pactl list short sources")
  if exitCode != 0:
    return

  for line in output.splitLines():
    let columns = line.split('\t')
    if columns.len >= 2 and columns[1].len > 0 and columns[1] notin result:
      result.add(columns[1])

proc matchingPreset*(state: RecorderState): string =
  if state.width == state.desktopWidth and state.height == state.desktopHeight and
      state.posX == 0 and state.posY == 0:
    return PresetFullScreen

  if state.width == 3840 and state.height == 2160:
    return "3840x2160"
  if state.width == 2560 and state.height == 1440:
    return "2560x1440"
  if state.width == 1920 and state.height == 1080:
    return "1920x1080"
  if state.width == 1280 and state.height == 720:
    return "1280x720"
  if state.width == 1080 and state.height == 1920:
    return "1080x1920 Shorts"

  PresetCustom

proc clampCaptureRect*(state: RecorderState) =
  let desktopWidth = max(state.desktopWidth, 1)
  let desktopHeight = max(state.desktopHeight, 1)

  state.width = clampInt(state.width, 16, desktopWidth)
  state.height = clampInt(state.height, 16, desktopHeight)
  state.posX = clampInt(state.posX, 0, max(0, desktopWidth - state.width))
  state.posY = clampInt(state.posY, 0, max(0, desktopHeight - state.height))

proc setCaptureRect*(state: RecorderState, x, y, width, height: int) =
  state.posX = x
  state.posY = y
  state.width = width
  state.height = height
  state.clampCaptureRect()
  state.preset = state.matchingPreset()

proc setCapturePosition*(state: RecorderState, x, y: int) =
  state.setCaptureRect(x, y, state.width, state.height)

proc setCaptureSize*(state: RecorderState, width, height: int) =
  state.setCaptureRect(state.posX, state.posY, width, height)

proc applyPreset*(state: RecorderState, preset: string) =
  case preset
  of PresetFullScreen:
    state.setCaptureRect(0, 0, state.desktopWidth, state.desktopHeight)
  of "3840x2160":
    state.setCaptureSize(3840, 2160)
  of "2560x1440":
    state.setCaptureSize(2560, 1440)
  of "1920x1080":
    state.setCaptureSize(1920, 1080)
  of "1280x720":
    state.setCaptureSize(1280, 720)
  of "1080x1920 Shorts":
    state.setCaptureSize(1080, 1920)
  else:
    state.preset = PresetCustom

proc newRecorderState*(): RecorderState =
  let desktopSize = detectDesktopSize()
  result = RecorderState(
    projectName: "",
    outputDir: defaultOutputDir(""),
    width: desktopSize.width,
    height: desktopSize.height,
    posX: 0,
    posY: 0,
    fps: 30,
    duration: 0,
    preset: PresetFullScreen,
    audioSource: DefaultAudioSource,
    isRecording: false,
    display: getEnv("DISPLAY", ":0.0"),
    desktopWidth: desktopSize.width,
    desktopHeight: desktopSize.height
  )
  result.clampCaptureRect()
