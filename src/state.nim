import json
import os
import osproc
import sequtils
import strutils

# Shared app state and local environment helpers used by both the UI and recorder.

############################
# Constants and Options
############################

const
  CaptureModeRegion* = "Region"
  CaptureModeWindow* = "Window"
  PresetFullScreen* = "Full Screen"
  PresetCustom* = "Custom"
  NoAudioSource* = "None"
  DefaultAudioSource* = "default"
  EncoderLibx264* = "libx264"
  EncoderVaapi* = "VAAPI"
  EncoderNvenc* = "NVENC"
  OutputFormatMp4* = "MP4"
  OutputFormatMkv* = "MKV"
  QualityFast* = "Fast"
  QualityBalanced* = "Balanced"
  QualityHigh* = "High"
  DefaultRecordHotkeyKey* = "R"
  DefaultPauseHotkeyKey* = "P"
  MaxRecentRecordings = 10
  NoWebcamDevice* = "(No webcam found)"
  WebcamSizeSmall* = "Small"
  WebcamSizeMedium* = "Medium"
  WebcamSizeLarge* = "Large"
  WebcamPositionTopLeft* = "Top Left"
  WebcamPositionTopRight* = "Top Right"
  WebcamPositionBottomLeft* = "Bottom Left"
  WebcamPositionBottomRight* = "Bottom Right"

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
  CountdownOptions* = @["0", "3", "5", "10"]
  CaptureModeOptions* = @[CaptureModeRegion, CaptureModeWindow]
  OutputFormatOptions* = @[OutputFormatMp4, OutputFormatMkv]
  QualityOptions* = @[QualityFast, QualityBalanced, QualityHigh]
  WebcamSizeOptions* = @[WebcamSizeSmall, WebcamSizeMedium, WebcamSizeLarge]
  WebcamPositionOptions* = @[
    WebcamPositionTopLeft,
    WebcamPositionTopRight,
    WebcamPositionBottomLeft,
    WebcamPositionBottomRight
  ]

############################
# Persistent State
############################

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
    countdown*: int
    captureMode*: string
    preset*: string
    audioSource*: string
    encoder*: string
    outputFormat*: string
    remuxToMp4*: bool
    quality*: string
    recordHotkeyKey*: string
    pauseHotkeyKey*: string
    hideWhileRecording*: bool
    webcamEnabled*: bool
    webcamDevice*: string
    webcamMirror*: bool
    webcamSize*: string
    webcamPosition*: string
    webcamMargin*: int
    targetWindowId*: string
    targetWindowTitle*: string
    projectSectionCollapsed*: bool
    captureSectionCollapsed*: bool
    recordingSectionCollapsed*: bool
    webcamSectionCollapsed*: bool
    actionsSectionCollapsed*: bool
    historySectionCollapsed*: bool
    previewSectionCollapsed*: bool
    recentRecordingPaths*: seq[string]
    display*: string
    desktopWidth*: int
    desktopHeight*: int

# Encoder discovery shells out to ffmpeg, so one process-wide cache is enough.
var cachedEncoders: seq[string]

############################
# Internal Helpers
############################

proc clampInt(value, minValue, maxValue: int): int =
  if value < minValue:
    return minValue
  if value > maxValue:
    return maxValue
  value

proc makeEven(value: int): int =
  if (value and 1) == 0:
    return value
  value - 1

proc gcdInt(a, b: int): int =
  var left = abs(a)
  var right = abs(b)
  while right != 0:
    let next = left mod right
    left = right
    right = next
  max(left, 1)

proc pathReadable*(path: string): bool =
  # Device nodes are not regular files, so existence checks must accept them too.
  try:
    discard getFileInfo(path)
    true
  except OSError:
    false

proc sanitizedProjectName*(projectName: string): string =
  # Keep generated paths predictable and shell-safe.
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
  # Default recordings go under the user's Videos directory.
  let videosDir = getHomeDir() / "Videos"
  let projectDir = sanitizedProjectName(projectName)
  if projectDir.len == 0:
    return videosDir
  videosDir / projectDir

proc settingsPath*(): string =
  getConfigDir() / "NimScreenRecorder" / "settings.json"

proc hotkeyKeyOptions*(): seq[string] =
  result = @[]
  for ch in 'A' .. 'Z':
    result.add($ch)
  for index in 1 .. 12:
    result.add("F" & $index)

proc hotkeyDescription*(key: string): string =
  "Ctrl+Alt+" & key

proc resolvedOutputDir*(path: string): string =
  # Expand "~" and relative paths so the UI can show the real recording target.
  let cleaned = path.strip()
  if cleaned.len == 0:
    return ""
  let expanded =
    if cleaned == "~":
      getHomeDir()
    elif cleaned.startsWith("~/"):
      getHomeDir() / cleaned[2 .. ^1]
    else:
      cleaned
  absolutePath(expanded)

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

############################
# Environment Discovery
############################

proc detectDesktopSize*(): tuple[width, height: int] =
  # Prefer desktop-reported size so the preview and preset math match the real display.
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
  # Keep a safe fallback even if PulseAudio/PipeWire source discovery fails.
  result = @[NoAudioSource, DefaultAudioSource]
  let (output, exitCode) = execCmdEx("pactl list short sources")
  if exitCode != 0:
    return

  for line in output.splitLines():
    let columns = line.split('\t')
    if columns.len >= 2 and columns[1].len > 0 and columns[1] notin result:
      result.add(columns[1])

proc webcamViewerAvailable*(): bool =
  findExe("ffplay").len > 0

proc windowCaptureAvailable*(): bool =
  findExe("xdotool").len > 0

proc hasNvidiaHardware(): bool =
  if pathReadable("/dev/nvidiactl") or pathReadable("/dev/nvidia0"):
    return true

  let (output, exitCode) = execCmdEx("lspci")
  exitCode == 0 and "NVIDIA" in output

proc hasVaapiHardware(): bool =
  pathReadable("/dev/dri/renderD128")

proc availableEncoders*(): seq[string] =
  # Offer only encoders that the local ffmpeg build and device stack can use.
  if cachedEncoders.len > 0:
    return cachedEncoders

  result = @[EncoderLibx264]
  let (output, exitCode) = execCmdEx("ffmpeg -hide_banner -encoders")
  if exitCode != 0:
    cachedEncoders = result
    return cachedEncoders

  if "h264_vaapi" in output and hasVaapiHardware():
    result.add(EncoderVaapi)

  if "h264_nvenc" in output and hasNvidiaHardware():
    result.add(EncoderNvenc)

  cachedEncoders = result

proc defaultEncoder*(): string =
  let encoders = availableEncoders()
  if EncoderVaapi in encoders:
    return EncoderVaapi
  if EncoderNvenc in encoders:
    return EncoderNvenc
  EncoderLibx264

############################
# Capture State
############################

proc outputExtension*(state: RecorderState): string =
  if state.outputFormat == OutputFormatMkv:
    "mkv"
  else:
    "mp4"

proc captureAspectRatio*(state: RecorderState): string =
  let divisor = gcdInt(state.width, state.height)
  $(state.width div divisor) & ":" & $(state.height div divisor)

proc captureModeLabel*(state: RecorderState): string =
  if state.captureMode == CaptureModeWindow:
    "Window"
  else:
    "Region"

proc matchingPreset*(state: RecorderState): string =
  # Used to keep the preset dropdown in sync when the region is edited manually.
  if state.captureMode == CaptureModeWindow:
    return PresetCustom

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
  # Keep the region on-screen and aligned to even dimensions for x264/yuv420p output.
  let desktopWidth = max(state.desktopWidth, 1)
  let desktopHeight = max(state.desktopHeight, 1)

  state.width = makeEven(clampInt(state.width, 16, desktopWidth))
  state.height = makeEven(clampInt(state.height, 16, desktopHeight))
  state.width = max(16, state.width)
  state.height = max(16, state.height)
  state.posX = clampInt(state.posX, 0, max(0, desktopWidth - state.width))
  state.posY = clampInt(state.posY, 0, max(0, desktopHeight - state.height))

proc setCaptureRect*(state: RecorderState, x, y, width, height: int) =
  state.posX = x
  state.posY = y
  state.width = width
  state.height = height
  state.clampCaptureRect()
  state.preset = state.matchingPreset()

proc useRegionCapture*(state: RecorderState) =
  state.captureMode = CaptureModeRegion
  state.targetWindowId = ""
  state.targetWindowTitle = ""
  state.preset = state.matchingPreset()

proc useWindowCapture*(state: RecorderState, windowId, windowTitle: string, x, y, width, height: int) =
  state.captureMode = CaptureModeWindow
  state.targetWindowId = windowId
  state.targetWindowTitle = windowTitle
  state.setCaptureRect(x, y, width, height)
  state.preset = PresetCustom

proc setCapturePosition*(state: RecorderState, x, y: int) =
  state.setCaptureRect(x, y, state.width, state.height)

proc setCaptureSize*(state: RecorderState, width, height: int) =
  state.setCaptureRect(state.posX, state.posY, width, height)

proc centerCaptureRect*(state: RecorderState) =
  # Handy for quickly recentring custom regions from the preview toolbar.
  state.posX = max(0, (state.desktopWidth - state.width) div 2)
  state.posY = max(0, (state.desktopHeight - state.height) div 2)
  state.clampCaptureRect()
  state.preset = state.matchingPreset()

proc applyPreset*(state: RecorderState, preset: string) =
  state.captureMode = CaptureModeRegion
  state.targetWindowId = ""
  state.targetWindowTitle = ""
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

proc validateForRecording*(state: RecorderState): seq[string] =
  # Gather all blocking issues at once so the UI can show one clear validation dialog.
  if findExe("ffmpeg").len == 0:
    result.add("ffmpeg is not installed or not on PATH.")
  if getEnv("DISPLAY", "").len == 0:
    result.add("DISPLAY is not set for X11 capture.")
  let outputDir = resolvedOutputDir(state.outputDir)
  if outputDir.len == 0:
    result.add("Output folder is empty.")
  if state.width <= 0 or state.height <= 0:
    result.add("Capture width and height must be greater than zero.")
  if state.fps <= 0:
    result.add("FPS must be greater than zero.")
  if state.duration < 0:
    result.add("Duration cannot be negative.")
  if state.captureMode == CaptureModeWindow and state.targetWindowId.len == 0:
    result.add("No window has been selected for window capture.")
  if state.encoder notin availableEncoders():
    result.add("Selected encoder is not available on this system.")
  if state.encoder == EncoderVaapi and not hasVaapiHardware():
    result.add("VAAPI encoder requires /dev/dri/renderD128.")
  if state.encoder == EncoderNvenc and not hasNvidiaHardware():
    result.add("NVENC encoder requires an NVIDIA GPU and driver.")

############################
# Output Paths and History
############################

proc buildOutputName*(state: RecorderState, timestamp: string): string =
  let projectName = sanitizedProjectName(state.projectName)
  let extension = state.outputExtension()
  if projectName.len == 0:
    return timestamp & "." & extension
  projectName & "_" & timestamp & "." & extension

proc buildPlannedOutputPath*(state: RecorderState, timestamp: string): string =
  let outputDir = resolvedOutputDir(state.outputDir)
  let fileName = state.buildOutputName(timestamp)
  if outputDir.len == 0:
    fileName
  else:
    outputDir / fileName

proc pushRecentRecording*(state: RecorderState, path: string) =
  if path.len == 0:
    return
  state.recentRecordingPaths.keepItIf(it != path)
  state.recentRecordingPaths.insert(path, 0)
  if state.recentRecordingPaths.len > MaxRecentRecordings:
    state.recentRecordingPaths.setLen(MaxRecentRecordings)

proc normalizeRecentRecordings(state: RecorderState) =
  state.recentRecordingPaths.keepItIf(it.len > 0)
  if state.recentRecordingPaths.len > MaxRecentRecordings:
    state.recentRecordingPaths.setLen(MaxRecentRecordings)

############################
# Settings Persistence
############################

proc saveSettings*(state: RecorderState) =
  # Persist user choices between launches without storing transient runtime state.
  let path = settingsPath()
  createDir(path.parentDir())

  let payload = %*{
    "projectName": state.projectName,
    "outputDir": state.outputDir,
    "width": state.width,
    "height": state.height,
    "posX": state.posX,
    "posY": state.posY,
    "fps": state.fps,
    "duration": state.duration,
    "countdown": state.countdown,
    "captureMode": state.captureMode,
    "preset": state.preset,
    "audioSource": state.audioSource,
    "encoder": state.encoder,
    "outputFormat": state.outputFormat,
    "remuxToMp4": state.remuxToMp4,
    "quality": state.quality,
    "recordHotkeyKey": state.recordHotkeyKey,
    "pauseHotkeyKey": state.pauseHotkeyKey,
    "hideWhileRecording": state.hideWhileRecording,
    "webcamEnabled": state.webcamEnabled,
    "webcamDevice": state.webcamDevice,
    "webcamMirror": state.webcamMirror,
    "webcamSize": state.webcamSize,
    "webcamPosition": state.webcamPosition,
    "webcamMargin": state.webcamMargin,
    "projectSectionCollapsed": state.projectSectionCollapsed,
    "captureSectionCollapsed": state.captureSectionCollapsed,
    "recordingSectionCollapsed": state.recordingSectionCollapsed,
    "webcamSectionCollapsed": state.webcamSectionCollapsed,
    "actionsSectionCollapsed": state.actionsSectionCollapsed,
    "historySectionCollapsed": state.historySectionCollapsed,
    "previewSectionCollapsed": state.previewSectionCollapsed,
    "recentRecordingPaths": state.recentRecordingPaths
  }

  writeFile(path, payload.pretty())

proc applySavedValue(node: JsonNode, key: string, value: var string) =
  if key in node and node[key].kind == JString:
    value = node[key].getStr()

proc applySavedValue(node: JsonNode, key: string, value: var int) =
  if key in node and node[key].kind in {JInt, JFloat}:
    value = node[key].getInt()

proc applySavedValue(node: JsonNode, key: string, value: var bool) =
  if key in node and node[key].kind == JBool:
    value = node[key].getBool()

proc applySavedStringSeq(node: JsonNode, key: string, value: var seq[string]) =
  if key notin node or node[key].kind != JArray:
    return
  value = @[]
  for item in node[key].items:
    if item.kind == JString and item.getStr().len > 0:
      value.add(item.getStr())

proc loadSettings*(state: RecorderState) =
  # Keep invalid or stale config values from breaking startup.
  let path = settingsPath()
  if not fileExists(path):
    return

  try:
    let saved = parseJson(readFile(path))
    saved.applySavedValue("projectName", state.projectName)
    saved.applySavedValue("outputDir", state.outputDir)
    saved.applySavedValue("width", state.width)
    saved.applySavedValue("height", state.height)
    saved.applySavedValue("posX", state.posX)
    saved.applySavedValue("posY", state.posY)
    saved.applySavedValue("fps", state.fps)
    saved.applySavedValue("duration", state.duration)
    saved.applySavedValue("countdown", state.countdown)
    saved.applySavedValue("captureMode", state.captureMode)
    saved.applySavedValue("preset", state.preset)
    saved.applySavedValue("audioSource", state.audioSource)
    saved.applySavedValue("encoder", state.encoder)
    saved.applySavedValue("outputFormat", state.outputFormat)
    saved.applySavedValue("remuxToMp4", state.remuxToMp4)
    saved.applySavedValue("quality", state.quality)
    saved.applySavedValue("recordHotkeyKey", state.recordHotkeyKey)
    saved.applySavedValue("pauseHotkeyKey", state.pauseHotkeyKey)
    saved.applySavedValue("hideWhileRecording", state.hideWhileRecording)
    saved.applySavedValue("webcamEnabled", state.webcamEnabled)
    saved.applySavedValue("webcamDevice", state.webcamDevice)
    saved.applySavedValue("webcamMirror", state.webcamMirror)
    saved.applySavedValue("webcamSize", state.webcamSize)
    saved.applySavedValue("webcamPosition", state.webcamPosition)
    saved.applySavedValue("webcamMargin", state.webcamMargin)
    saved.applySavedValue("projectSectionCollapsed", state.projectSectionCollapsed)
    saved.applySavedValue("captureSectionCollapsed", state.captureSectionCollapsed)
    saved.applySavedValue("recordingSectionCollapsed", state.recordingSectionCollapsed)
    saved.applySavedValue("webcamSectionCollapsed", state.webcamSectionCollapsed)
    saved.applySavedValue("actionsSectionCollapsed", state.actionsSectionCollapsed)
    saved.applySavedValue("historySectionCollapsed", state.historySectionCollapsed)
    saved.applySavedValue("previewSectionCollapsed", state.previewSectionCollapsed)
    saved.applySavedStringSeq("recentRecordingPaths", state.recentRecordingPaths)
  except CatchableError:
    discard

  if state.captureMode == CaptureModeWindow:
    state.useRegionCapture()
  if state.encoder notin availableEncoders():
    state.encoder = defaultEncoder()
  if state.outputFormat notin OutputFormatOptions:
    state.outputFormat = OutputFormatMkv
  if state.recordHotkeyKey notin hotkeyKeyOptions():
    state.recordHotkeyKey = DefaultRecordHotkeyKey
  if state.pauseHotkeyKey notin hotkeyKeyOptions():
    state.pauseHotkeyKey = DefaultPauseHotkeyKey
  if state.quality notin QualityOptions:
    state.quality = QualityBalanced
  if state.webcamSize notin WebcamSizeOptions:
    state.webcamSize = WebcamSizeMedium
  if state.webcamPosition notin WebcamPositionOptions:
    state.webcamPosition = WebcamPositionTopRight
  state.webcamMargin = max(0, state.webcamMargin)
  state.normalizeRecentRecordings()
  state.clampCaptureRect()
  state.preset = state.matchingPreset()

############################
# Default State
############################

proc newRecorderState*(): RecorderState =
  # Start from the current desktop so the prototype is ready to record immediately.
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
    countdown: 0,
    captureMode: CaptureModeRegion,
    preset: PresetFullScreen,
    audioSource: DefaultAudioSource,
    encoder: defaultEncoder(),
    outputFormat: OutputFormatMkv,
    remuxToMp4: false,
    quality: QualityBalanced,
    recordHotkeyKey: DefaultRecordHotkeyKey,
    pauseHotkeyKey: DefaultPauseHotkeyKey,
    hideWhileRecording: false,
    webcamEnabled: false,
    webcamDevice: NoWebcamDevice,
    webcamMirror: false,
    webcamSize: WebcamSizeMedium,
    webcamPosition: WebcamPositionTopRight,
    webcamMargin: 20,
    targetWindowId: "",
    targetWindowTitle: "",
    projectSectionCollapsed: false,
    captureSectionCollapsed: false,
    recordingSectionCollapsed: false,
    webcamSectionCollapsed: true,
    actionsSectionCollapsed: false,
    historySectionCollapsed: false,
    previewSectionCollapsed: false,
    recentRecordingPaths: @[],
    display: getEnv("DISPLAY", ":0.0"),
    desktopWidth: desktopSize.width,
    desktopHeight: desktopSize.height
  )
  result.clampCaptureRect()
