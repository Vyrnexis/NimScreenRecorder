import os
import osproc
import strutils
import times

import nigui

import appicon
import hotkey
import notify
import preview
import recorder
import restorefix
import state
import webcam
import windowpicker

# Main NiGui window assembly and all user-facing interaction wiring.

############################
# UI State
############################

const NoRecentRecordingsLabel = "(No recent recordings)"

type
  RecorderUi* = ref object
    # Window and runtime state.
    window*: Window
    state*: RecorderState
    recorder*: Recorder
    preview*: DesktopPreview
    hotkey*: GlobalHotkeyController
    pollTimer: Timer
    hotkeyTimer: Timer
    restoreWindowTimer: Timer
    countdownTimer: Timer
    countdownRemaining: int
    recordingStartedAt: float
    pausedStartedAt: float
    pausedAccumulatedSeconds: float
    recordingBlinkOn: bool
    lastRecorderRunning: bool
    lastHandledCompletionSerial: int
    windowHiddenForRecording: bool
    pendingFailureMessage: string
    currentIconState: string
    syncingFields: bool
    outputDirCustomized: bool

    # Project and capture controls.
    projectNameBox: TextBox
    outputDirBox: TextBox
    outputDirBrowseButton: Button
    profileCombo: ComboBox
    captureModeCombo: ComboBox
    regionCaptureGroup: LayoutContainer
    windowCaptureGroup: LayoutContainer
    presetCombo: ComboBox
    widthBox: TextBox
    heightBox: TextBox
    xBox: TextBox
    yBox: TextBox
    selectedWindowBox: TextBox
    pickWindowButton: Button
    refreshWindowButton: Button
    windowDependencyLabel: Label

    # Recording controls.
    fpsCombo: ComboBox
    durationBox: TextBox
    countdownCombo: ComboBox
    audioCombo: ComboBox
    audioRefreshButton: Button
    encoderCombo: ComboBox
    outputFormatCombo: ComboBox
    remuxToMp4Check: Checkbox
    qualityCombo: ComboBox
    hideWhileRecordingCheck: Checkbox
    webcamEnabledCheck: Checkbox
    webcamDeviceCombo: ComboBox
    webcamMirrorCheck: Checkbox
    webcamSizeCombo: ComboBox
    webcamPositionCombo: ComboBox
    webcamMarginBox: TextBox
    webcamDependencyLabel: Label
    startButton: Button
    pauseButton: Button
    stopButton: Button
    recentRecordingsCombo: ComboBox
    openLastRecordingButton: Button
    copyLastPathButton: Button
    openLastLogButton: Button
    recordHotkeyCombo: ComboBox
    pauseHotkeyCombo: ComboBox
    hotkeySummaryLabel: Label

    # Preview and status widgets.
    centerRegionButton: Button
    previewHeaderBar: LayoutContainer
    previewGlyphLabel: Label
    previewTitleLabel: Label
    statusBadgeLabel: Label
    statusLabel: Label
    statusMetaLabel: Label

proc syncFieldsFromState(ui: RecorderUi)
proc updateStatusMeta(ui: RecorderUi)
proc handleHotkeyAction(ui: RecorderUi, action: HotkeyAction)
proc stopRecordingFlow(ui: RecorderUi)
proc beginRecording(ui: RecorderUi)
proc scheduleWindowRestore(ui: RecorderUi, delayMs: int)
proc selectedWindowLabel(state: RecorderState): string
proc togglePauseFlow(ui: RecorderUi)
proc markProfileCustom(ui: RecorderUi)

############################
# Shared UI Helpers
############################

proc updateWindowIcon(ui: RecorderUi, state: string) =
  if ui.window == nil or ui.currentIconState == state:
    return

  let iconPath = resolveIconPath(state)
  if iconPath.len == 0:
    return

  try:
    ui.window.iconPath = iconPath
    ui.currentIconState = state
  except CatchableError:
    discard

proc sendRecordingNotification(ui: RecorderUi, title, body, iconState: string, urgency = "normal") =
  # Notifications matter most when the app minimizes itself during recording.
  if not ui.state.hideWhileRecording and not ui.windowHiddenForRecording:
    return
  sendNotification(title, body, iconState, urgency)

proc timerActive(timer: Timer): bool =
  timer.int != inactiveTimer

proc settingsLocked(ui: RecorderUi): bool =
  ui.recorder.isRunning() or ui.countdownTimer.timerActive()

proc stopTimer(timer: var Timer) =
  # NiGui timers are distinct ints, so normalize "inactive" handling in one place.
  if timer.timerActive():
    timer.stop()
    timer = Timer(inactiveTimer)

proc tryParseInt(text: string, value: var int): bool =
  try:
    value = text.strip().parseInt()
    true
  except ValueError:
    false

proc newFormRow(labelText: string, control: Control): LayoutContainer =
  # Standard full-width form row used by the settings cards.
  result = newLayoutContainer(Layout_Horizontal)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Auto
  result.spacing = 8
  result.yAlign = YAlign_Center
  result.padding = 2

  let label = newLabel("  " & labelText)
  label.width = 104.scaleToDpi
  label.xTextAlign = XTextAlign_Left
  label.yTextAlign = YTextAlign_Center
  result.add(label)

  control.widthMode = WidthMode_Expand
  result.add(control)

proc newCompactField(labelText: string, control: Control): LayoutContainer =
  # Smaller field layout used when two related values share one row.
  result = newLayoutContainer(Layout_Horizontal)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Auto
  result.spacing = 6
  result.yAlign = YAlign_Center
  result.padding = 2

  let label = newLabel("  " & labelText)
  label.width = 68.scaleToDpi
  label.xTextAlign = XTextAlign_Left
  label.yTextAlign = YTextAlign_Center
  result.add(label)

  control.widthMode = WidthMode_Expand
  result.add(control)

proc newFixedFieldWithLabelWidth(
    labelText: string,
    control: Control,
    labelWidth: int,
    controlWidth: int
): LayoutContainer =
  # Fixed-width inputs keep short controls from consuming more space than they need.
  result = newLayoutContainer(Layout_Horizontal)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Auto
  result.spacing = 6
  result.yAlign = YAlign_Center
  result.padding = 2

  let label = newLabel("  " & labelText)
  label.width = labelWidth.scaleToDpi
  label.xTextAlign = XTextAlign_Left
  label.yTextAlign = YTextAlign_Center
  result.add(label)

  control.widthMode = WidthMode_Auto
  control.width = controlWidth.scaleToDpi
  result.add(control)

proc newPairedRow(leftLabel: string, leftControl: Control, rightLabel: string, rightControl: Control): LayoutContainer =
  result = newLayoutContainer(Layout_Horizontal)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Auto
  result.spacing = 10

  let leftField = newCompactField(leftLabel, leftControl)
  let rightField = newCompactField(rightLabel, rightControl)
  leftField.widthMode = WidthMode_Expand
  rightField.widthMode = WidthMode_Expand
  result.add(leftField)
  result.add(rightField)

proc newHotkeyRow(recordControl: Control, pauseControl: Control): LayoutContainer =
  result = newLayoutContainer(Layout_Horizontal)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Auto
  result.spacing = 10

  let recordField = newFixedFieldWithLabelWidth("Record key", recordControl, 86, 72)
  let pauseField = newFixedFieldWithLabelWidth("Pause key", pauseControl, 82, 72)
  recordField.widthMode = WidthMode_Expand
  pauseField.widthMode = WidthMode_Expand
  result.add(recordField)
  result.add(pauseField)

proc newFieldHeader(text: string): Label =
  result = newLabel(text)
  result.fontBold = true
  result.widthMode = WidthMode_Expand
  result.textColor = rgb(70, 70, 82)

proc styleSectionBody(container: LayoutContainer) =
  # Shared card body styling for sidebar sections.
  container.padding = 10
  container.spacing = 10
  container.backgroundColor = rgb(248, 249, 252)

proc updateSectionGlyph(glyphLabel: Label, expanded: bool) =
  glyphLabel.text = if expanded: "  ▾" else: "  ▸"

proc newCollapsibleSection(
    title: string,
    collapsed = false,
    onToggle: proc(collapsed: bool) = nil
  ): tuple[root, header, body: LayoutContainer, glyphLabel, titleLabel: Label] =
  # Simple accordion section built from a clickable title bar and a body container.
  result.root = newLayoutContainer(Layout_Vertical)
  result.root.widthMode = WidthMode_Expand
  result.root.heightMode = HeightMode_Auto
  result.root.spacing = 0
  result.root.backgroundColor = rgb(248, 249, 252)

  result.header = newLayoutContainer(Layout_Horizontal)
  result.header.widthMode = WidthMode_Expand
  result.header.heightMode = HeightMode_Auto
  result.header.spacing = 0
  result.header.padding = 0
  result.header.yAlign = YAlign_Center
  result.header.backgroundColor = rgb(70, 92, 128)
  result.header.height = 32.scaleToDpi

  result.glyphLabel = newLabel("")
  result.glyphLabel.width = 34.scaleToDpi
  result.glyphLabel.height = 32.scaleToDpi
  result.glyphLabel.fontBold = true
  result.glyphLabel.fontSize = 16
  result.glyphLabel.textColor = rgb(255, 255, 255)
  result.glyphLabel.backgroundColor = rgb(70, 92, 128)
  result.glyphLabel.yTextAlign = YTextAlign_Center
  result.glyphLabel.xTextAlign = XTextAlign_Left
  result.header.add(result.glyphLabel)

  result.titleLabel = newLabel(title)
  result.titleLabel.fontBold = true
  result.titleLabel.fontSize = 17
  result.titleLabel.widthMode = WidthMode_Expand
  result.titleLabel.height = 32.scaleToDpi
  result.titleLabel.textColor = rgb(255, 255, 255)
  result.titleLabel.backgroundColor = rgb(70, 92, 128)
  result.titleLabel.xTextAlign = XTextAlign_Left
  result.titleLabel.yTextAlign = YTextAlign_Center
  result.header.add(result.titleLabel)

  result.body = newLayoutContainer(Layout_Vertical)
  result.body.widthMode = WidthMode_Expand
  result.body.heightMode = HeightMode_Auto
  result.body.visible = not collapsed
  result.body.styleSectionBody()

  let body = result.body
  let titleLabel = result.titleLabel
  let glyphLabel = result.glyphLabel
  proc toggleSection() =
    body.visible = not body.visible
    updateSectionGlyph(glyphLabel, body.visible)
    if onToggle != nil:
      onToggle(not body.visible)

  updateSectionGlyph(glyphLabel, not collapsed)
  result.header.onClick = proc(event: ClickEvent) =
    toggleSection()
  glyphLabel.onClick = proc(event: ClickEvent) =
    toggleSection()
  titleLabel.onClick = proc(event: ClickEvent) =
    toggleSection()

  result.root.add(result.header)
  result.root.add(result.body)

############################
# Derived UI State
############################

proc updateDefaultOutputDir(ui: RecorderUi) =
  # Auto-follow project name until the user explicitly chooses a custom folder.
  if ui.outputDirCustomized:
    return
  ui.state.outputDir = defaultOutputDir(ui.state.projectName)
  if ui.outputDirBox != nil:
    ui.outputDirBox.text = ui.state.outputDir
  ui.updateStatusMeta()

proc updateStatusMeta(ui: RecorderUi) =
  # Keep compact derived recording details in the status bar instead of the sidebar.
  if ui.statusMetaLabel == nil:
    return

  let fileLabel =
    if ui.recorder != nil and ui.recorder.isRunning() and ui.recorder.currentOutput.len > 0:
      extractFilename(ui.recorder.currentOutput)
    else:
      let timestamp = now().format("yyyy-MM-dd'_'HH-mm-ss")
      extractFilename(ui.state.buildPlannedOutputPath(timestamp))

  let sourceLabel =
    if ui.state.captureMode == CaptureModeWindow:
      "Window: " & selectedWindowLabel(ui.state)
    else:
      "Region"

  ui.statusMetaLabel.text =
    "Source: " & sourceLabel &
    "   File: " & fileLabel &
    "   Aspect: " & ui.state.captureAspectRatio()

proc markProfileCustom(ui: RecorderUi) =
  if ui.state.profile == ProfileCustom:
    return
  ui.state.profile = ProfileCustom
  if ui.profileCombo != nil:
    ui.profileCombo.value = ProfileCustom

proc selectedWindowLabel(state: RecorderState): string =
  if state.targetWindowTitle.len > 0:
    state.targetWindowTitle
  elif state.targetWindowId.len > 0:
    "Window " & state.targetWindowId
  else:
    "No window selected"

proc updateStatus(ui: RecorderUi, text: string, color: Color = rgb(46, 76, 124)) =
  if ui.statusLabel != nil:
    ui.statusLabel.text = text
    ui.statusLabel.textColor = color

proc openPath(ui: RecorderUi, path, failureTitle: string): bool =
  if path.len == 0:
    alert(ui.window, "Nothing is available yet.", failureTitle)
    return false

  try:
    let process = startProcess(
      "setsid",
      args = @["-f", "xdg-open", path],
      options = {poUsePath, poDaemon, poStdErrToStdOut}
    )
    process.close()
    return true
  except CatchableError:
    alert(ui.window, "Could not open: " & path, failureTitle)
    return false

proc latestRecordingPath(ui: RecorderUi): string =
  if ui.recorder == nil:
    return if ui.state.recentRecordingPaths.len > 0: ui.state.recentRecordingPaths[0] else: ""
  if ui.recorder.currentOutput.len > 0:
    return ui.recorder.currentOutput
  if ui.state.recentRecordingPaths.len > 0:
    return ui.state.recentRecordingPaths[0]
  ""

proc latestLogPath(ui: RecorderUi): string =
  if ui.recorder == nil:
    return ""
  if ui.recorder.lastLogPath.len > 0:
    return ui.recorder.lastLogPath
  ""

proc selectedRecentRecordingPath(ui: RecorderUi): string =
  if ui.recentRecordingsCombo == nil or ui.recentRecordingsCombo.value == NoRecentRecordingsLabel:
    return ""
  ui.recentRecordingsCombo.value

proc refreshRecentRecordings(ui: RecorderUi) =
  if ui.recentRecordingsCombo == nil:
    return

  let options =
    if ui.state.recentRecordingPaths.len > 0:
      ui.state.recentRecordingPaths
    else:
      @[NoRecentRecordingsLabel]
  ui.recentRecordingsCombo.options = options
  ui.recentRecordingsCombo.value = options[0]

proc rebuildHotkeys(ui: RecorderUi) =
  if ui.hotkey != nil:
    ui.hotkey.close()
  ui.hotkey = newGlobalHotkeyController(ui.state.recordHotkeyKey, ui.state.pauseHotkeyKey)

proc updateHotkeySummary(ui: RecorderUi) =
  if ui.hotkeySummaryLabel == nil:
    return
  ui.hotkeySummaryLabel.text =
    "Hotkeys use " &
    hotkeyDescription(ui.state.recordHotkeyKey) &
    " and " &
    hotkeyDescription(ui.state.pauseHotkeyKey)

proc showPendingFailure(ui: RecorderUi) =
  if ui.pendingFailureMessage.len == 0 or ui.windowHiddenForRecording:
    return
  alert(ui.window, ui.pendingFailureMessage, "Recording Failed")
  ui.pendingFailureMessage = ""

proc updateProjectControls(ui: RecorderUi) =
  let locked = ui.settingsLocked()
  if ui.projectNameBox != nil:
    ui.projectNameBox.editable = not locked
  if ui.outputDirBox != nil:
    ui.outputDirBox.editable = false
  if ui.outputDirBrowseButton != nil:
    ui.outputDirBrowseButton.enabled = not locked
  if ui.profileCombo != nil:
    ui.profileCombo.enabled = not locked

proc updateCaptureControls(ui: RecorderUi) =
  let locked = ui.settingsLocked()
  let windowSupport = windowCaptureAvailable()

  if not windowSupport and ui.state.captureMode == CaptureModeWindow:
    ui.state.useRegionCapture()
  let windowMode = ui.state.captureMode == CaptureModeWindow

  if ui.captureModeCombo != nil:
    ui.captureModeCombo.enabled = not locked
  if ui.regionCaptureGroup != nil:
    ui.regionCaptureGroup.visible = not windowMode
  if ui.windowCaptureGroup != nil:
    ui.windowCaptureGroup.visible = windowMode or not windowSupport
  if ui.presetCombo != nil:
    ui.presetCombo.enabled = not locked and not windowMode
  if ui.widthBox != nil:
    ui.widthBox.editable = not locked and not windowMode
  if ui.heightBox != nil:
    ui.heightBox.editable = not locked and not windowMode
  if ui.xBox != nil:
    ui.xBox.editable = not locked and not windowMode
  if ui.yBox != nil:
    ui.yBox.editable = not locked and not windowMode
  if ui.selectedWindowBox != nil:
    ui.selectedWindowBox.editable = false
    ui.selectedWindowBox.text =
      if windowSupport:
        selectedWindowLabel(ui.state)
      else:
        "xdotool not found"
  if ui.pickWindowButton != nil:
    ui.pickWindowButton.text = if ui.state.targetWindowId.len > 0: "Re-pick" else: "Pick Window"
    ui.pickWindowButton.enabled = windowSupport and not locked and windowMode
  if ui.refreshWindowButton != nil:
    ui.refreshWindowButton.enabled = windowSupport and not locked and windowMode and ui.state.targetWindowId.len > 0
  if ui.windowDependencyLabel != nil:
    ui.windowDependencyLabel.visible = not windowSupport

proc updateRecordingControls(ui: RecorderUi) =
  let locked = ui.settingsLocked()
  if ui.fpsCombo != nil:
    ui.fpsCombo.enabled = not locked
  if ui.durationBox != nil:
    ui.durationBox.editable = not locked
  if ui.countdownCombo != nil:
    ui.countdownCombo.enabled = not locked
  if ui.audioCombo != nil:
    ui.audioCombo.enabled = not locked
  if ui.audioRefreshButton != nil:
    ui.audioRefreshButton.enabled = not locked
  if ui.encoderCombo != nil:
    ui.encoderCombo.enabled = not locked
  if ui.outputFormatCombo != nil:
    ui.outputFormatCombo.enabled = not locked
  if ui.remuxToMp4Check != nil:
    ui.remuxToMp4Check.enabled = not locked and ui.state.outputFormat == OutputFormatMkv
  if ui.qualityCombo != nil:
    ui.qualityCombo.enabled = not locked
  if ui.hideWhileRecordingCheck != nil:
    ui.hideWhileRecordingCheck.enabled = not locked

proc updateWebcamControls(ui: RecorderUi) =
  # Keep webcam-specific controls inactive until the user enables the webcam window.
  if ui.webcamEnabledCheck == nil:
    return

  let viewerAvailable = webcamViewerAvailable()
  let deviceAvailable = hasWebcamDevice(ui.state.webcamDevice)
  let windowMode = ui.state.captureMode == CaptureModeWindow
  let locked = ui.settingsLocked()
  if not viewerAvailable or not deviceAvailable:
    ui.state.webcamEnabled = false
  if windowMode and ui.state.webcamEnabled:
    ui.state.webcamEnabled = false
    ui.recorder.hideWebcamWindow()
    ui.updateStatus("Webcam window is only available in Region mode")

  ui.webcamEnabledCheck.enabled = viewerAvailable and deviceAvailable and not windowMode and not locked
  let overlayEnabled = viewerAvailable and deviceAvailable and ui.state.webcamEnabled and not windowMode and not locked
  if ui.webcamDeviceCombo != nil:
    ui.webcamDeviceCombo.enabled = deviceAvailable and not windowMode and not locked
  if ui.webcamMirrorCheck != nil:
    ui.webcamMirrorCheck.enabled = overlayEnabled
  if ui.webcamSizeCombo != nil:
    ui.webcamSizeCombo.enabled = overlayEnabled
  if ui.webcamPositionCombo != nil:
    ui.webcamPositionCombo.enabled = overlayEnabled
  if ui.webcamMarginBox != nil:
    ui.webcamMarginBox.editable = overlayEnabled
  if ui.webcamDependencyLabel != nil:
    ui.webcamDependencyLabel.visible = not viewerAvailable

proc refreshWebcamWindow(ui: RecorderUi) =
  # Recreate the webcam window whenever its settings change so the geometry stays in sync.
  if not ui.state.webcamEnabled:
    ui.recorder.hideWebcamWindow()
    ui.updateStatus("Webcam window closed")
    return

  try:
    ui.recorder.showWebcamWindow(ui.state)
    ui.updateStatus("Webcam window opened")
  except CatchableError:
    ui.state.webcamEnabled = false
    ui.syncFieldsFromState()
    alert(ui.window, getCurrentExceptionMsg(), "Webcam Window Failed")

proc refreshCaptureUi(ui: RecorderUi, repositionWebcam = false) =
  # One sync point keeps the form fields, preview, and webcam placement consistent.
  ui.syncFieldsFromState()
  if repositionWebcam and ui.state.webcamEnabled:
    ui.refreshWebcamWindow()

proc refreshSelectedWindow(ui: RecorderUi) =
  if ui.state.targetWindowId.len == 0:
    return

  let selection = queryWindow(ui.state.targetWindowId)
  ui.state.useWindowCapture(
    selection.id,
    selection.title,
    selection.x,
    selection.y,
    selection.width,
    selection.height
  )
  ui.refreshCaptureUi(repositionWebcam = true)
  ui.preview.forceRedraw()

proc updateWindowRecordingState(ui: RecorderUi, running: bool) =
  # Mirror recording state in the window title so it is visible even when the app is unfocused.
  if ui.window == nil:
    return
  if running and ui.recorder.isPaused():
    ui.window.title = "Nim Screen Recorder [PAUSED]"
    ui.updateWindowIcon(IconStatePaused)
  elif running:
    ui.window.title = "Nim Screen Recorder [RECORDING]"
    ui.updateWindowIcon(IconStateRecording)
  else:
    ui.window.title = "Nim Screen Recorder"
    ui.updateWindowIcon(IconStateIdle)

proc restoreWindowFromRecording(ui: RecorderUi) =
  if ui.window == nil or not ui.windowHiddenForRecording:
    return
  ui.restoreWindowTimer.stopTimer()
  ui.window.minimized = false
  restoreWindow(ui.window)
  ui.windowHiddenForRecording = false

proc scheduleWindowRestore(ui: RecorderUi, delayMs: int) =
  if ui.window == nil or not ui.windowHiddenForRecording:
    return

  ui.restoreWindowTimer.stopTimer()
  ui.restoreWindowTimer = startRepeatingTimer(delayMs, proc(event: TimerEvent) =
    let ui = cast[RecorderUi](event.data)
    if ui == nil:
      return
    ui.restoreWindowTimer.stopTimer()
    ui.restoreWindowFromRecording()
  , cast[pointer](ui))

proc updatePreviewRecordingState(ui: RecorderUi, running: bool) =
  # The preview header changing color makes recording state obvious without another popup.
  if ui.previewTitleLabel == nil:
    return
  let headerColor =
    if running and ui.recorder.isPaused():
      rgb(191, 128, 36)
    elif running:
      rgb(168, 54, 54)
    else:
      rgb(70, 92, 128)

  if running and ui.recorder.isPaused():
    ui.previewTitleLabel.text = "Preview Panel  PAUSED"
  elif running:
    ui.previewTitleLabel.text = "Preview Panel  RECORDING"
  else:
    ui.previewTitleLabel.text = "Preview Panel"
  ui.previewTitleLabel.backgroundColor = headerColor
  if ui.previewGlyphLabel != nil:
    ui.previewGlyphLabel.backgroundColor = headerColor
  if ui.previewHeaderBar != nil:
    ui.previewHeaderBar.backgroundColor = headerColor

proc formatElapsed(secondsTotal: int): string =
  let hours = secondsTotal div 3600
  let minutes = (secondsTotal mod 3600) div 60
  let seconds = secondsTotal mod 60
  result = align($hours, 2, '0') & ":" & align($minutes, 2, '0') & ":" & align($seconds, 2, '0')

proc activeRecordingSeconds(ui: RecorderUi): int =
  if ui.recordingStartedAt <= 0:
    return 0

  let pausedSeconds =
    if ui.recorder.isPaused() and ui.pausedStartedAt > 0:
      ui.pausedAccumulatedSeconds + max(0.0, epochTime() - ui.pausedStartedAt)
    else:
      ui.pausedAccumulatedSeconds

  max(0, int(epochTime() - ui.recordingStartedAt - pausedSeconds))

proc updateButtons(ui: RecorderUi) =
  # Centralized UI-state refresh for buttons, badge, title, and status line.
  let running = ui.recorder.isRunning()
  let paused = ui.recorder.isPaused()
  let countingDown = ui.countdownTimer.timerActive()

  if ui.recorder.completionSerial != ui.lastHandledCompletionSerial:
    ui.lastHandledCompletionSerial = ui.recorder.completionSerial
    if ui.recorder.lastEndedUnexpectedly:
      let logInfo =
        if ui.recorder.lastLogPath.len > 0:
          "\n\nLog: " & ui.recorder.lastLogPath
        else:
          ""
      ui.pendingFailureMessage =
        "FFmpeg exited unexpectedly (" & $ui.recorder.lastExitCode & ")." &
        (if ui.recorder.lastFailureSummary.len > 0: "\n\n" & ui.recorder.lastFailureSummary else: "") &
        logInfo
      ui.updateStatus("Recording failed", rgb(160, 54, 54))
      ui.sendRecordingNotification(
        "Recording failed",
        (if ui.recorder.lastFailureSummary.len > 0: ui.recorder.lastFailureSummary else: "FFmpeg exited unexpectedly."),
        IconStateRecording,
        urgency = "critical"
      )

  # A stopped recorder should bring back the minimized window regardless of how it ended.
  if ui.lastRecorderRunning and not running and ui.windowHiddenForRecording:
    ui.scheduleWindowRestore(250)
    if ui.pendingFailureMessage.len == 0:
      ui.sendRecordingNotification(
        "Recording saved",
        extractFilename(ui.recorder.currentOutput),
        IconStateIdle
      )

  ui.startButton.enabled = not running and not countingDown
  ui.pauseButton.enabled = running
  ui.stopButton.enabled = running
  if ui.recentRecordingsCombo != nil:
    ui.recentRecordingsCombo.enabled = ui.state.recentRecordingPaths.len > 0
  if ui.openLastRecordingButton != nil:
    ui.openLastRecordingButton.enabled = ui.latestRecordingPath().fileExists()
  if ui.copyLastPathButton != nil:
    ui.copyLastPathButton.enabled = ui.latestRecordingPath().len > 0
  if ui.openLastLogButton != nil:
    ui.openLastLogButton.enabled = ui.latestLogPath().fileExists()
  if ui.recordHotkeyCombo != nil:
    ui.recordHotkeyCombo.enabled = not ui.settingsLocked()
  if ui.pauseHotkeyCombo != nil:
    ui.pauseHotkeyCombo.enabled = not ui.settingsLocked()
  ui.startButton.text = if countingDown: "Countdown..." elif running: "Recording..." else: "Start Recording"
  ui.pauseButton.text = if paused: "Resume Recording" else: "Pause Recording"
  ui.stopButton.text = if running: "Stop Recording" else: "Stop"
  ui.updateWindowRecordingState(running)
  ui.updatePreviewRecordingState(running)
  ui.updateProjectControls()
  ui.updateCaptureControls()
  ui.updateRecordingControls()
  ui.updateWebcamControls()
  if ui.preview != nil:
    ui.preview.setRecordingActive(running)
    ui.preview.setPausedActive(paused)
    ui.preview.setCountdownSeconds(if countingDown: ui.countdownRemaining else: 0)
  if ui.centerRegionButton != nil:
    ui.centerRegionButton.enabled = not ui.settingsLocked() and ui.state.captureMode == CaptureModeRegion

  if ui.statusBadgeLabel != nil:
    if paused:
      ui.statusBadgeLabel.text = " PAUSE "
      ui.statusBadgeLabel.textColor = rgb(255, 255, 255)
      ui.statusBadgeLabel.backgroundColor = rgb(191, 128, 36)
    elif running:
      ui.statusBadgeLabel.text = " REC "
      ui.statusBadgeLabel.textColor = rgb(255, 255, 255)
      ui.statusBadgeLabel.backgroundColor =
        if ui.recordingBlinkOn: rgb(190, 48, 48) else: rgb(132, 38, 38)
    elif countingDown:
      ui.statusBadgeLabel.text = " " & $ui.countdownRemaining & "s "
      ui.statusBadgeLabel.textColor = rgb(255, 255, 255)
      ui.statusBadgeLabel.backgroundColor = rgb(205, 128, 34)
    else:
      ui.statusBadgeLabel.text = " READY "
      ui.statusBadgeLabel.textColor = rgb(255, 255, 255)
      ui.statusBadgeLabel.backgroundColor = rgb(66, 126, 84)

  if paused:
    ui.updateStatus("Paused  " & formatElapsed(ui.activeRecordingSeconds()), rgb(166, 102, 28))
  elif running:
    let elapsed = ui.activeRecordingSeconds()
    ui.updateStatus("Recording  " & formatElapsed(elapsed))
  elif not countingDown and ui.pendingFailureMessage.len == 0:
    ui.updateStatus("Idle")

  ui.lastRecorderRunning = running
  ui.updateStatusMeta()
  ui.refreshRecentRecordings()
  ui.showPendingFailure()

############################
# Event Handlers
############################

proc syncFieldsFromState(ui: RecorderUi) =
  # Prevent event handlers from fighting back while the UI is being refreshed programmatically.
  ui.syncingFields = true
  defer:
    ui.syncingFields = false

  ui.projectNameBox.text = ui.state.projectName
  ui.outputDirBox.text = ui.state.outputDir
  ui.profileCombo.value = ui.state.profile
  ui.captureModeCombo.value = ui.state.captureMode
  ui.presetCombo.value = ui.state.preset
  ui.widthBox.text = $ui.state.width
  ui.heightBox.text = $ui.state.height
  ui.xBox.text = $ui.state.posX
  ui.yBox.text = $ui.state.posY
  ui.fpsCombo.value = $ui.state.fps
  ui.durationBox.text = $ui.state.duration
  ui.countdownCombo.value = $ui.state.countdown
  ui.audioCombo.value = ui.state.audioSource
  ui.encoderCombo.value = ui.state.encoder
  ui.outputFormatCombo.value = ui.state.outputFormat
  ui.remuxToMp4Check.checked = ui.state.remuxToMp4
  ui.qualityCombo.value = ui.state.quality
  ui.recordHotkeyCombo.value = ui.state.recordHotkeyKey
  ui.pauseHotkeyCombo.value = ui.state.pauseHotkeyKey
  ui.updateHotkeySummary()
  ui.hideWhileRecordingCheck.checked = ui.state.hideWhileRecording
  ui.webcamEnabledCheck.checked = ui.state.webcamEnabled
  ui.webcamDeviceCombo.value = ui.state.webcamDevice
  ui.webcamMirrorCheck.checked = ui.state.webcamMirror
  ui.webcamSizeCombo.value = ui.state.webcamSize
  ui.webcamPositionCombo.value = ui.state.webcamPosition
  ui.webcamMarginBox.text = $ui.state.webcamMargin
  ui.updateStatusMeta()
  ui.refreshRecentRecordings()
  ui.updateCaptureControls()
  ui.updateWebcamControls()
  ui.updateButtons()

proc handlePreviewChanged(ui: RecorderUi) =
  # Preview dragging updates the fields live, but avoid restarting ffplay on every mouse move.
  ui.refreshCaptureUi()

proc handlePreviewFinished(ui: RecorderUi) =
  # Apply webcam repositioning once after a preview drag finishes.
  ui.refreshCaptureUi(repositionWebcam = true)

proc togglePauseFlow(ui: RecorderUi) =
  # Pause/resume splits the recording into kept segments so paused time is skipped.
  if not ui.recorder.isRunning():
    return

  try:
    if ui.recorder.isPaused():
      ui.recorder.resumeRecording(ui.state)
      if ui.pausedStartedAt > 0:
        ui.pausedAccumulatedSeconds += max(0.0, epochTime() - ui.pausedStartedAt)
      ui.pausedStartedAt = 0
      ui.updateStatus("Recording resumed")
      ui.sendRecordingNotification(
        "Recording resumed",
        extractFilename(ui.recorder.currentOutput),
        IconStateRecording
      )
    else:
      ui.recorder.pauseRecording()
      ui.pausedStartedAt = epochTime()
      ui.updateStatus("Recording paused", rgb(166, 102, 28))
      ui.sendRecordingNotification(
        "Recording paused",
        extractFilename(ui.recorder.currentOutput),
        IconStatePaused
      )
    ui.updateButtons()
  except CatchableError:
    alert(ui.window, getCurrentExceptionMsg(), "Pause Recording Failed")

proc handleHotkeyAction(ui: RecorderUi, action: HotkeyAction) =
  # Global hotkeys keep recording control available while the app is minimized.
  case action
  of HotkeyRecordToggle:
    if ui.countdownTimer.timerActive():
      ui.countdownTimer.stopTimer()
      ui.updateStatus("Countdown cancelled")
      ui.updateButtons()
    elif ui.recorder.isRunning():
      ui.stopRecordingFlow()
    else:
      ui.beginRecording()
  of HotkeyPauseToggle:
    ui.togglePauseFlow()
  of HotkeyNone:
    discard

proc stopRecordingFlow(ui: RecorderUi) =
  let countdownActive = ui.countdownTimer.timerActive()
  ui.countdownTimer.stopTimer()
  # Stop can also be hit during countdown or window teardown, so only finalize a live session.
  if not ui.recorder.isRunning():
    if countdownActive:
      ui.updateStatus("Countdown cancelled")
      ui.updateButtons()
    return
  if ui.recorder.isPaused() and ui.pausedStartedAt > 0:
    ui.pausedAccumulatedSeconds += max(0.0, epochTime() - ui.pausedStartedAt)
  ui.pausedStartedAt = 0
  ui.updateStatus("Finalizing recording...")
  ui.recorder.stopRecording(ui.state)
  ui.recordingBlinkOn = true

proc startRecordingNow(ui: RecorderUi) =
  # Actual recorder launch happens here; countdown logic lives separately.
  try:
    ui.restoreWindowTimer.stopTimer()
    discard ui.recorder.startRecording(ui.state)
    ui.recordingStartedAt = epochTime()
    ui.pausedStartedAt = 0
    ui.pausedAccumulatedSeconds = 0
    if ui.state.hideWhileRecording:
      ui.window.minimize()
      ui.windowHiddenForRecording = true
    else:
      ui.windowHiddenForRecording = false
    ui.sendRecordingNotification(
      "Recording started",
      extractFilename(ui.recorder.currentOutput),
      IconStateRecording
    )
    ui.updateButtons()
  except CatchableError:
    alert(ui.window, getCurrentExceptionMsg(), "Start Recording Failed")
    ui.updateButtons()

proc countdownTick(event: TimerEvent) =
  # Countdown is shown in the status bar and badge until it reaches zero.
  let ui = cast[RecorderUi](event.data)
  if ui == nil:
    return

  ui.countdownRemaining.dec()
  if ui.countdownRemaining <= 0:
    ui.countdownTimer.stopTimer()
    ui.startRecordingNow()
  else:
    ui.updateStatus("Recording starts in " & $ui.countdownRemaining & "...")
    ui.updateButtons()

proc beginRecording(ui: RecorderUi) =
  # Shared entry point for validation, countdown setup, and immediate recording start.
  if ui.state.captureMode == CaptureModeWindow:
    try:
      ui.refreshSelectedWindow()
    except CatchableError:
      ui.state.clearWindowSelection()
      ui.syncFieldsFromState()
      alert(ui.window, getCurrentExceptionMsg(), "Window Capture Failed")
      return

  let issues = ui.state.validateForRecording()
  if issues.len > 0:
    alert(ui.window, issues.join("\n"), "Recording Validation Failed")
    return

  ui.state.outputDir = resolvedOutputDir(ui.state.outputDir)
  ui.pendingFailureMessage = ""
  if ui.state.countdown > 0:
    ui.countdownRemaining = ui.state.countdown
    ui.updateStatus("Recording starts in " & $ui.countdownRemaining & "...")
    ui.countdownTimer.stopTimer()
    ui.countdownTimer = startRepeatingTimer(1000, countdownTick, cast[pointer](ui))
    ui.updateButtons()
  else:
    ui.startRecordingNow()

proc openOutputFolder(ui: RecorderUi) =
  # Launch detached so a file manager window cannot block app shutdown.
  let outputDir = resolvedOutputDir(ui.state.outputDir)
  if outputDir.len == 0:
    alert(ui.window, "Output folder is empty.", "Open Folder Failed")
    return

  createDir(outputDir)
  try:
    let process = startProcess(
      "setsid",
      args = @["-f", "xdg-open", outputDir],
      options = {poUsePath, poDaemon, poStdErrToStdOut}
    )
    process.close()
    ui.updateStatus("Opened output folder")
  except CatchableError:
    alert(ui.window, "Could not open the output folder.", "Open Folder Failed")

############################
# GUI Project Settings
############################

proc buildProjectSettings(ui: RecorderUi): LayoutContainer =
  # Project-related settings are kept together because they affect output path generation.
  let section = newCollapsibleSection(
    "Project Settings",
    collapsed = ui.state.projectSectionCollapsed,
    onToggle = proc(collapsed: bool) =
      ui.state.projectSectionCollapsed = collapsed
  )
  result = section.root
  let body = section.body

  ui.projectNameBox = newTextBox(ui.state.projectName)
  ui.projectNameBox.placeholder = "Untitled project"
  ui.projectNameBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    ui.state.projectName = ui.projectNameBox.text
    ui.updateDefaultOutputDir()
    ui.updateStatusMeta()
  body.add(newFormRow("Project name", ui.projectNameBox))

  ui.profileCombo = newComboBox(ProfileOptions)
  ui.profileCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    if ui.profileCombo.value == ProfileCustom:
      ui.state.profile = ProfileCustom
      return
    ui.state.applyProfile(ui.profileCombo.value)
    ui.refreshCaptureUi(repositionWebcam = true)
    ui.preview.forceRedraw()
    ui.updateStatus("Applied profile: " & ui.state.profile)
  body.add(newFormRow("Profile", ui.profileCombo))

  ui.outputDirBox = newTextBox(ui.state.outputDir)
  ui.outputDirBox.placeholder = defaultOutputDir("")
  ui.outputDirBox.editable = false
  ui.outputDirBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    ui.state.outputDir = ui.outputDirBox.text
    ui.outputDirCustomized = ui.outputDirBox.text.strip().len > 0 and
      ui.outputDirBox.text != defaultOutputDir(ui.state.projectName)
    ui.updateStatusMeta()

  ui.outputDirBrowseButton = newButton("Browse")
  ui.outputDirBrowseButton.onClick = proc(event: ClickEvent) =
    var dialog = newSelectDirectoryDialog()
    dialog.title = "Select Output Folder"
    dialog.startDirectory = ui.state.outputDir
    dialog.run()
    if dialog.selectedDirectory.len > 0:
      ui.state.outputDir = dialog.selectedDirectory
      ui.outputDirCustomized = true
      ui.syncFieldsFromState()

  let folderField = newLayoutContainer(Layout_Vertical)
  folderField.widthMode = WidthMode_Expand
  folderField.heightMode = HeightMode_Auto
  folderField.spacing = 6
  folderField.add(newFieldHeader("Output folder"))

  let folderRow = newLayoutContainer(Layout_Horizontal)
  folderRow.widthMode = WidthMode_Expand
  folderRow.heightMode = HeightMode_Auto
  folderRow.spacing = 8
  ui.outputDirBox.widthMode = WidthMode_Expand
  folderRow.add(ui.outputDirBox)
  ui.outputDirBrowseButton.width = 92.scaleToDpi
  folderRow.add(ui.outputDirBrowseButton)
  folderField.add(folderRow)
  body.add(folderField)

############################
# GUI Capture Settings
############################

proc buildCaptureSettings(ui: RecorderUi): LayoutContainer =
  # Capture settings are mirrored by the preview rectangle in both directions.
  let section = newCollapsibleSection(
    "Capture Settings",
    collapsed = ui.state.captureSectionCollapsed,
    onToggle = proc(collapsed: bool) =
      ui.state.captureSectionCollapsed = collapsed
  )
  result = section.root
  let body = section.body

  let captureModes =
    if windowCaptureAvailable():
      CaptureModeOptions
    else:
      @[CaptureModeRegion]

  ui.captureModeCombo = newComboBox(captureModes)
  ui.captureModeCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    ui.markProfileCustom()
    if ui.captureModeCombo.value == CaptureModeWindow:
      ui.state.captureMode = CaptureModeWindow
      if ui.state.webcamEnabled:
        ui.state.webcamEnabled = false
        ui.recorder.hideWebcamWindow()
        ui.updateStatus("Webcam window is only available in Region mode")
      if ui.state.targetWindowId.len > 0:
        try:
          ui.refreshSelectedWindow()
        except CatchableError:
          discard
      ui.updateCaptureControls()
      ui.preview.forceRedraw()
      if ui.state.targetWindowId.len == 0:
        ui.updateStatus("Pick a window to start window capture")
    else:
      ui.state.useRegionCapture()
      ui.refreshCaptureUi(repositionWebcam = true)
      ui.preview.forceRedraw()
  body.add(newFormRow("Mode", ui.captureModeCombo))

  ui.windowCaptureGroup = newLayoutContainer(Layout_Vertical)
  ui.windowCaptureGroup.widthMode = WidthMode_Expand
  ui.windowCaptureGroup.heightMode = HeightMode_Auto
  ui.windowCaptureGroup.spacing = 10

  ui.windowDependencyLabel = newLabel("Window capture requires xdotool.")
  ui.windowDependencyLabel.textColor = rgb(166, 102, 28)
  ui.windowDependencyLabel.widthMode = WidthMode_Expand
  ui.windowCaptureGroup.add(ui.windowDependencyLabel)

  ui.selectedWindowBox = newTextBox(selectedWindowLabel(ui.state))
  ui.selectedWindowBox.editable = false

  ui.pickWindowButton = newButton("Pick Window")
  ui.pickWindowButton.onClick = proc(event: ClickEvent) =
    try:
      ui.markProfileCustom()
      let selection = pickWindow()
      ui.state.useWindowCapture(
        selection.id,
        selection.title,
        selection.x,
        selection.y,
        selection.width,
        selection.height
      )
      ui.refreshCaptureUi(repositionWebcam = true)
      ui.preview.forceRedraw()
      ui.updateStatus("Window selected: " & selection.title)
    except CatchableError:
      ui.updateStatus("Window selection cancelled")

  ui.refreshWindowButton = newButton("Refresh Bounds")
  ui.refreshWindowButton.onClick = proc(event: ClickEvent) =
    try:
      ui.refreshSelectedWindow()
      ui.updateStatus("Window bounds refreshed")
    except CatchableError:
      ui.state.clearWindowSelection()
      ui.syncFieldsFromState()
      alert(ui.window, getCurrentExceptionMsg(), "Refresh Window Failed")

  let windowField = newLayoutContainer(Layout_Vertical)
  windowField.widthMode = WidthMode_Expand
  windowField.heightMode = HeightMode_Auto
  windowField.spacing = 6
  windowField.add(newFieldHeader("Selected window"))

  let windowRow = newLayoutContainer(Layout_Horizontal)
  windowRow.widthMode = WidthMode_Expand
  windowRow.heightMode = HeightMode_Auto
  windowRow.spacing = 8
  ui.selectedWindowBox.widthMode = WidthMode_Expand
  ui.selectedWindowBox.minWidth = 108.scaleToDpi
  ui.pickWindowButton.width = 114.scaleToDpi
  ui.refreshWindowButton.width = 132.scaleToDpi
  windowRow.add(ui.selectedWindowBox)
  windowRow.add(ui.pickWindowButton)
  windowRow.add(ui.refreshWindowButton)
  windowField.add(windowRow)
  ui.windowCaptureGroup.add(windowField)
  body.add(ui.windowCaptureGroup)

  ui.regionCaptureGroup = newLayoutContainer(Layout_Vertical)
  ui.regionCaptureGroup.widthMode = WidthMode_Expand
  ui.regionCaptureGroup.heightMode = HeightMode_Auto
  ui.regionCaptureGroup.spacing = 10

  ui.presetCombo = newComboBox(ResolutionPresetOptions)
  ui.presetCombo.minWidth = 180.scaleToDpi
  ui.presetCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    ui.markProfileCustom()
    ui.state.applyPreset(ui.presetCombo.value)
    ui.refreshCaptureUi(repositionWebcam = true)
    ui.preview.forceRedraw()
  ui.regionCaptureGroup.add(newFormRow("Preset", ui.presetCombo))

  ui.widthBox = newTextBox($ui.state.width)
  ui.widthBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.widthBox.text, value):
      ui.markProfileCustom()
      ui.state.setCaptureSize(value, ui.state.height)
      ui.refreshCaptureUi(repositionWebcam = true)

  ui.heightBox = newTextBox($ui.state.height)
  ui.heightBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.heightBox.text, value):
      ui.markProfileCustom()
      ui.state.setCaptureSize(ui.state.width, value)
      ui.refreshCaptureUi(repositionWebcam = true)
  ui.regionCaptureGroup.add(newPairedRow("Width", ui.widthBox, "Height", ui.heightBox))

  ui.xBox = newTextBox($ui.state.posX)
  ui.xBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.xBox.text, value):
      ui.markProfileCustom()
      ui.state.setCapturePosition(value, ui.state.posY)
      ui.refreshCaptureUi(repositionWebcam = true)

  ui.yBox = newTextBox($ui.state.posY)
  ui.yBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.yBox.text, value):
      ui.markProfileCustom()
      ui.state.setCapturePosition(ui.state.posX, value)
      ui.refreshCaptureUi(repositionWebcam = true)
  ui.regionCaptureGroup.add(newPairedRow("X", ui.xBox, "Y", ui.yBox))
  body.add(ui.regionCaptureGroup)

############################
# GUI Recording Settings
############################

proc buildRecordingSettings(ui: RecorderUi): LayoutContainer =
  # Recording settings affect ffmpeg runtime behavior rather than the preview geometry.
  let section = newCollapsibleSection(
    "Recording Settings",
    collapsed = ui.state.recordingSectionCollapsed,
    onToggle = proc(collapsed: bool) =
      ui.state.recordingSectionCollapsed = collapsed
  )
  result = section.root
  let body = section.body

  ui.fpsCombo = newComboBox(FpsOptions)
  ui.fpsCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.fpsCombo.value, value):
      ui.markProfileCustom()
      ui.state.fps = value

  ui.durationBox = newTextBox($ui.state.duration)
  ui.durationBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.durationBox.text, value):
      ui.markProfileCustom()
      ui.state.duration = max(0, value)
  body.add(newPairedRow("FPS", ui.fpsCombo, "Duration", ui.durationBox))

  ui.countdownCombo = newComboBox(CountdownOptions)
  ui.countdownCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.countdownCombo.value, value):
      ui.markProfileCustom()
      ui.state.countdown = max(0, value)
  body.add(newFormRow("Countdown", ui.countdownCombo))

  let refreshAudioSources = proc() =
    let audioOptions = detectAudioSources()
    ui.audioCombo.options = audioOptions
    if ui.state.audioSource notin audioOptions:
      ui.state.audioSource = NoAudioSource
    ui.audioCombo.value = ui.state.audioSource

  ui.audioCombo = newComboBox(detectAudioSources())
  if ui.state.audioSource notin ui.audioCombo.options:
    ui.state.audioSource = NoAudioSource
  ui.audioCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    ui.markProfileCustom()
    ui.state.audioSource = ui.audioCombo.value

  ui.audioRefreshButton = newButton("Refresh")
  ui.audioRefreshButton.width = 92.scaleToDpi
  ui.audioRefreshButton.onClick = proc(event: ClickEvent) =
    refreshAudioSources()
    ui.updateStatus("Audio sources refreshed")

  let audioRow = newLayoutContainer(Layout_Horizontal)
  audioRow.widthMode = WidthMode_Expand
  audioRow.heightMode = HeightMode_Auto
  audioRow.spacing = 8
  ui.audioCombo.widthMode = WidthMode_Expand
  audioRow.add(ui.audioCombo)
  audioRow.add(ui.audioRefreshButton)
  body.add(newFormRow("Audio source", audioRow))

  let encoders = availableEncoders()
  if ui.state.encoder notin encoders:
    ui.state.encoder = encoders[0]

  ui.encoderCombo = newComboBox(encoders)
  ui.encoderCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    ui.markProfileCustom()
    ui.state.encoder = ui.encoderCombo.value

  ui.outputFormatCombo = newComboBox(OutputFormatOptions)
  ui.outputFormatCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    ui.markProfileCustom()
    ui.state.outputFormat = ui.outputFormatCombo.value
    ui.updateStatusMeta()

  ui.remuxToMp4Check = newCheckbox("Also remux MKV to MP4 after stop")
  ui.remuxToMp4Check.onToggle = proc(event: ToggleEvent) =
    if ui.syncingFields:
      return
    ui.markProfileCustom()
    ui.state.remuxToMp4 = ui.remuxToMp4Check.checked

  ui.qualityCombo = newComboBox(QualityOptions)
  ui.qualityCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    ui.markProfileCustom()
    ui.state.quality = ui.qualityCombo.value

  body.add(newPairedRow("Encoder", ui.encoderCombo, "Format", ui.outputFormatCombo))
  body.add(ui.remuxToMp4Check)
  body.add(newFormRow("Quality", ui.qualityCombo))

  ui.hideWhileRecordingCheck = newCheckbox("Hide app during recording")
  ui.hideWhileRecordingCheck.onToggle = proc(event: ToggleEvent) =
    if ui.syncingFields:
      return
    ui.markProfileCustom()
    ui.state.hideWhileRecording = ui.hideWhileRecordingCheck.checked
  body.add(ui.hideWhileRecordingCheck)

  let hotkeyOptions = hotkeyKeyOptions()
  ui.recordHotkeyCombo = newComboBox(hotkeyOptions)
  ui.recordHotkeyCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    if ui.recordHotkeyCombo.value == ui.state.pauseHotkeyKey:
      ui.syncFieldsFromState()
      alert(ui.window, "Record and pause hotkeys must use different keys.", "Hotkey Conflict")
      return
    ui.state.recordHotkeyKey = ui.recordHotkeyCombo.value
    ui.rebuildHotkeys()
    ui.updateHotkeySummary()
    ui.updateStatus("Updated record hotkey to " & hotkeyDescription(ui.state.recordHotkeyKey))

  ui.pauseHotkeyCombo = newComboBox(hotkeyOptions)
  ui.pauseHotkeyCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    if ui.pauseHotkeyCombo.value == ui.state.recordHotkeyKey:
      ui.syncFieldsFromState()
      alert(ui.window, "Record and pause hotkeys must use different keys.", "Hotkey Conflict")
      return
    ui.state.pauseHotkeyKey = ui.pauseHotkeyCombo.value
    ui.rebuildHotkeys()
    ui.updateHotkeySummary()
    ui.updateStatus("Updated pause hotkey to " & hotkeyDescription(ui.state.pauseHotkeyKey))

  body.add(newHotkeyRow(ui.recordHotkeyCombo, ui.pauseHotkeyCombo))

  ui.hotkeySummaryLabel = newLabel("")
  ui.hotkeySummaryLabel.textColor = rgb(74, 96, 132)
  ui.hotkeySummaryLabel.fontBold = true
  ui.hotkeySummaryLabel.fontSize = 13
  ui.hotkeySummaryLabel.widthMode = WidthMode_Expand
  ui.hotkeySummaryLabel.xTextAlign = XTextAlign_Center
  ui.updateHotkeySummary()
  body.add(ui.hotkeySummaryLabel)

############################
# GUI Webcam Settings
############################

proc buildWebcamSettings(ui: RecorderUi): LayoutContainer =
  # Webcam stays in its own window so recording can keep using the fast screen-only path.
  let section = newCollapsibleSection(
    "Webcam Window",
    collapsed = ui.state.webcamSectionCollapsed,
    onToggle = proc(collapsed: bool) =
      ui.state.webcamSectionCollapsed = collapsed
  )
  result = section.root
  let body = section.body

  ui.webcamDependencyLabel = newLabel("Webcam window requires ffplay.")
  ui.webcamDependencyLabel.textColor = rgb(166, 102, 28)
  ui.webcamDependencyLabel.widthMode = WidthMode_Expand
  body.add(ui.webcamDependencyLabel)

  let webcamDevices = detectWebcamDevices()
  if ui.state.webcamDevice notin webcamDevices:
    ui.state.webcamDevice = webcamDevices[0]

  ui.webcamEnabledCheck = newCheckbox("Show webcam window")
  ui.webcamEnabledCheck.onToggle = proc(event: ToggleEvent) =
    if ui.syncingFields:
      return
    ui.state.webcamEnabled = ui.webcamEnabledCheck.checked
    ui.updateWebcamControls()
    ui.refreshWebcamWindow()
  body.add(ui.webcamEnabledCheck)

  ui.webcamDeviceCombo = newComboBox(webcamDevices)
  ui.webcamDeviceCombo.value = ui.state.webcamDevice
  ui.webcamDeviceCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    ui.state.webcamDevice = ui.webcamDeviceCombo.value
    if ui.state.webcamDevice == NoWebcamDevice:
      ui.state.webcamEnabled = false
      ui.recorder.hideWebcamWindow()
      ui.syncFieldsFromState()
    else:
      ui.updateWebcamControls()
      ui.refreshWebcamWindow()
  body.add(newFormRow("Device", ui.webcamDeviceCombo))

  ui.webcamMirrorCheck = newCheckbox("Mirror webcam")
  ui.webcamMirrorCheck.onToggle = proc(event: ToggleEvent) =
    if ui.syncingFields:
      return
    ui.state.webcamMirror = ui.webcamMirrorCheck.checked
    ui.refreshWebcamWindow()
  body.add(ui.webcamMirrorCheck)

  ui.webcamSizeCombo = newComboBox(WebcamSizeOptions)
  ui.webcamSizeCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    ui.state.webcamSize = ui.webcamSizeCombo.value
    ui.refreshWebcamWindow()
  body.add(newFormRow("Size", ui.webcamSizeCombo))

  ui.webcamPositionCombo = newComboBox(WebcamPositionOptions)
  ui.webcamPositionCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    ui.state.webcamPosition = ui.webcamPositionCombo.value
    ui.refreshWebcamWindow()
  body.add(newFormRow("Position", ui.webcamPositionCombo))

  ui.webcamMarginBox = newTextBox($ui.state.webcamMargin)
  ui.webcamMarginBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.webcamMarginBox.text, value):
      ui.state.webcamMargin = max(0, value)
      ui.refreshWebcamWindow()
  body.add(newFormRow("Margin", ui.webcamMarginBox))

proc initializeWebcamState(ui: RecorderUi) =
  # Pick a usable webcam device once during startup so the UI opens in a valid state.
  let webcamDevices = detectWebcamDevices()
  if ui.state.webcamDevice notin webcamDevices:
    ui.state.webcamDevice = webcamDevices[0]

############################
# GUI Actions
############################

proc buildActionsSection(ui: RecorderUi): LayoutContainer =
  # Action section keeps the control surface small and obvious.
  let section = newCollapsibleSection(
    "Actions",
    collapsed = ui.state.actionsSectionCollapsed,
    onToggle = proc(collapsed: bool) =
      ui.state.actionsSectionCollapsed = collapsed
  )
  result = section.root
  let body = section.body

  let buttonRow = newLayoutContainer(Layout_Horizontal)
  buttonRow.widthMode = WidthMode_Expand
  buttonRow.heightMode = HeightMode_Auto
  buttonRow.spacing = 8

  ui.startButton = newButton("Start Recording")
  ui.startButton.widthMode = WidthMode_Expand
  ui.startButton.minWidth = 150.scaleToDpi
  ui.startButton.onClick = proc(event: ClickEvent) =
    ui.beginRecording()
  buttonRow.add(ui.startButton)

  ui.pauseButton = newButton("Pause Recording")
  ui.pauseButton.widthMode = WidthMode_Expand
  ui.pauseButton.minWidth = 150.scaleToDpi
  ui.pauseButton.onClick = proc(event: ClickEvent) =
    ui.togglePauseFlow()
  buttonRow.add(ui.pauseButton)

  ui.stopButton = newButton("Stop Recording")
  ui.stopButton.widthMode = WidthMode_Expand
  ui.stopButton.minWidth = 150.scaleToDpi
  ui.stopButton.onClick = proc(event: ClickEvent) =
    ui.stopRecordingFlow()
  buttonRow.add(ui.stopButton)
  body.add(buttonRow)

  let utilityRow = newLayoutContainer(Layout_Horizontal)
  utilityRow.widthMode = WidthMode_Expand
  utilityRow.heightMode = HeightMode_Auto
  utilityRow.spacing = 8

  let openFolderButton = newButton("Open Folder")
  openFolderButton.widthMode = WidthMode_Expand
  openFolderButton.onClick = proc(event: ClickEvent) =
    ui.openOutputFolder()
  utilityRow.add(openFolderButton)
  body.add(utilityRow)

############################
# GUI History
############################

proc buildHistorySection(ui: RecorderUi): LayoutContainer =
  let section = newCollapsibleSection(
    "History",
    collapsed = ui.state.historySectionCollapsed,
    onToggle = proc(collapsed: bool) =
      ui.state.historySectionCollapsed = collapsed
  )
  result = section.root
  let body = section.body

  ui.recentRecordingsCombo = newComboBox(@[NoRecentRecordingsLabel])
  ui.recentRecordingsCombo.widthMode = WidthMode_Expand
  body.add(newFormRow("Recent", ui.recentRecordingsCombo))

  let topRow = newLayoutContainer(Layout_Horizontal)
  topRow.widthMode = WidthMode_Expand
  topRow.heightMode = HeightMode_Auto
  topRow.spacing = 8

  ui.openLastRecordingButton = newButton("Open Latest")
  ui.openLastRecordingButton.widthMode = WidthMode_Expand
  ui.openLastRecordingButton.onClick = proc(event: ClickEvent) =
    if ui.openPath(ui.latestRecordingPath(), "Open Recording Failed"):
      ui.updateStatus("Opened latest recording")
  topRow.add(ui.openLastRecordingButton)

  ui.copyLastPathButton = newButton("Copy Latest Path")
  ui.copyLastPathButton.widthMode = WidthMode_Expand
  ui.copyLastPathButton.onClick = proc(event: ClickEvent) =
    let outputPath = ui.latestRecordingPath()
    if outputPath.len == 0:
      alert(ui.window, "No recording has been created yet.", "Copy Path Failed")
      return
    app.clipboardText = outputPath
    ui.updateStatus("Copied latest recording path")
  topRow.add(ui.copyLastPathButton)
  body.add(topRow)

  let bottomRow = newLayoutContainer(Layout_Horizontal)
  bottomRow.widthMode = WidthMode_Expand
  bottomRow.heightMode = HeightMode_Auto
  bottomRow.spacing = 8

  let openRecentButton = newButton("Open Selected")
  openRecentButton.widthMode = WidthMode_Expand
  openRecentButton.onClick = proc(event: ClickEvent) =
    let path = ui.selectedRecentRecordingPath()
    if path.len == 0:
      return
    if ui.openPath(path, "Open Selected Failed"):
      ui.updateStatus("Opened selected recording")
  bottomRow.add(openRecentButton)

  let copyRecentButton = newButton("Copy Selected Path")
  copyRecentButton.widthMode = WidthMode_Expand
  copyRecentButton.onClick = proc(event: ClickEvent) =
    let path = ui.selectedRecentRecordingPath()
    if path.len == 0:
      return
    app.clipboardText = path
    ui.updateStatus("Copied selected recording path")
  bottomRow.add(copyRecentButton)
  body.add(bottomRow)

  let logRow = newLayoutContainer(Layout_Horizontal)
  logRow.widthMode = WidthMode_Expand
  logRow.heightMode = HeightMode_Auto
  logRow.spacing = 8
  ui.openLastLogButton = newButton("Open Last Log")
  ui.openLastLogButton.widthMode = WidthMode_Expand
  ui.openLastLogButton.onClick = proc(event: ClickEvent) =
    if ui.openPath(ui.latestLogPath(), "Open Log Failed"):
      ui.updateStatus("Opened last FFmpeg log")
  logRow.add(ui.openLastLogButton)
  body.add(logRow)

############################
# GUI Preview
############################

proc buildPreviewPanel(ui: RecorderUi): LayoutContainer =
  # Preview owns the visual editing surface plus the lightweight helper controls around it.
  let section = newCollapsibleSection(
    "Preview Panel",
    collapsed = ui.state.previewSectionCollapsed,
    onToggle = proc(collapsed: bool) =
      ui.state.previewSectionCollapsed = collapsed
  )
  result = section.root
  result.heightMode = HeightMode_Expand
  let body = section.body
  ui.previewHeaderBar = section.header
  ui.previewGlyphLabel = section.glyphLabel
  ui.previewTitleLabel = section.titleLabel

  ui.preview = newDesktopPreview(
    ui.state,
    proc() = ui.handlePreviewChanged(),
    proc() = ui.handlePreviewFinished()
  )
  body.add(ui.preview)

  let bottomRow = newLayoutContainer(Layout_Horizontal)
  bottomRow.widthMode = WidthMode_Expand
  bottomRow.heightMode = HeightMode_Auto
  bottomRow.spacing = 8
  bottomRow.yAlign = YAlign_Center

  let hint = newLabel("Region mode: drag to move or resize. Window mode: pick and sync a window.")
  hint.widthMode = WidthMode_Expand
  hint.textColor = rgb(92, 92, 104)
  hint.yTextAlign = YTextAlign_Center
  bottomRow.add(hint)

  let toolbar = newLayoutContainer(Layout_Horizontal)
  toolbar.heightMode = HeightMode_Auto
  toolbar.spacing = 8
  toolbar.xAlign = XAlign_Right

  ui.centerRegionButton = newButton("Center Region")
  ui.centerRegionButton.onClick = proc(event: ClickEvent) =
    ui.state.centerCaptureRect()
    ui.refreshCaptureUi(repositionWebcam = true)
    ui.preview.forceRedraw()
    ui.updateStatus("Capture region centered")
  toolbar.add(ui.centerRegionButton)
  bottomRow.add(toolbar)
  body.add(bottomRow)

############################
# Main Window Assembly
############################

proc newRecorderUi*(): RecorderUi =
  # Compose the full window: left settings sidebar, right preview, bottom status bar.
  let ui = RecorderUi(
    state: newRecorderState(),
    recorder: newRecorder(),
    hotkey: nil
  )
  ui.state.loadSettings()
  ui.outputDirCustomized = ui.state.outputDir != defaultOutputDir(ui.state.projectName)
  ui.rebuildHotkeys()
  ui.initializeWebcamState()

  ui.window = newWindow("Nim Screen Recorder")
  ui.window.width = 1340.scaleToDpi
  ui.window.height = 980.scaleToDpi
  ui.window.minWidth = 1120.scaleToDpi
  ui.window.minHeight = 820.scaleToDpi

  let root = newLayoutContainer(Layout_Vertical)
  root.widthMode = WidthMode_Expand
  root.heightMode = HeightMode_Expand
  root.spacing = 16
  root.padding = 16
  root.backgroundColor = rgb(232, 235, 240)

  let mainRow = newLayoutContainer(Layout_Horizontal)
  mainRow.widthMode = WidthMode_Expand
  mainRow.heightMode = HeightMode_Expand
  mainRow.spacing = 16
  mainRow.backgroundColor = rgb(232, 235, 240)

  let sidebar = newLayoutContainer(Layout_Vertical)
  sidebar.width = 460.scaleToDpi
  sidebar.heightMode = HeightMode_Expand
  sidebar.spacing = 12
  sidebar.backgroundColor = rgb(232, 235, 240)

  let projectSection = ui.buildProjectSettings()
  projectSection.widthMode = WidthMode_Expand

  let captureSection = ui.buildCaptureSettings()
  captureSection.widthMode = WidthMode_Expand

  let recordingSection = ui.buildRecordingSettings()
  recordingSection.widthMode = WidthMode_Expand

  let webcamSection = ui.buildWebcamSettings()
  webcamSection.widthMode = WidthMode_Expand

  let actionSection = ui.buildActionsSection()
  actionSection.widthMode = WidthMode_Expand

  let historySection = ui.buildHistorySection()
  historySection.widthMode = WidthMode_Expand

  sidebar.add(projectSection)
  sidebar.add(captureSection)
  sidebar.add(recordingSection)
  sidebar.add(webcamSection)
  sidebar.add(actionSection)
  sidebar.add(historySection)

  let previewPanel = ui.buildPreviewPanel()
  previewPanel.widthMode = WidthMode_Expand
  previewPanel.heightMode = HeightMode_Expand

  mainRow.add(sidebar)
  mainRow.add(previewPanel)
  root.add(mainRow)

  let statusBar = newLayoutContainer(Layout_Horizontal)
  statusBar.widthMode = WidthMode_Expand
  statusBar.heightMode = HeightMode_Auto
  statusBar.spacing = 8
  statusBar.padding = 8
  statusBar.yAlign = YAlign_Center
  statusBar.backgroundColor = rgb(216, 220, 227)

  ui.statusBadgeLabel = newLabel(" READY ")
  ui.statusBadgeLabel.width = 80.scaleToDpi
  ui.statusBadgeLabel.fontBold = true
  ui.statusBadgeLabel.xTextAlign = XTextAlign_Center
  ui.statusBadgeLabel.yTextAlign = YTextAlign_Center
  statusBar.add(ui.statusBadgeLabel)

  ui.statusLabel = newLabel("Idle")
  ui.statusLabel.fontBold = true
  ui.statusLabel.textColor = rgb(46, 76, 124)
  ui.statusLabel.widthMode = WidthMode_Expand
  ui.statusLabel.xTextAlign = XTextAlign_Left
  ui.statusLabel.yTextAlign = YTextAlign_Center
  statusBar.add(ui.statusLabel)

  ui.statusMetaLabel = newLabel("")
  ui.statusMetaLabel.textColor = rgb(74, 74, 90)
  ui.statusMetaLabel.widthMode = WidthMode_Expand
  ui.statusMetaLabel.xTextAlign = XTextAlign_Right
  ui.statusMetaLabel.yTextAlign = YTextAlign_Center
  statusBar.add(ui.statusMetaLabel)

  root.add(statusBar)
  ui.window.add(root)

  ui.window.onCloseClick = proc(event: CloseClickEvent) =
    # Always stop timers and ffmpeg before disposing the window.
    ui.pollTimer.stopTimer()
    ui.hotkeyTimer.stopTimer()
    ui.restoreWindowTimer.stopTimer()
    ui.preview.stopPreview()
    ui.windowHiddenForRecording = false
    ui.stopRecordingFlow()
    ui.recorder.hideWebcamWindow()
    ui.hotkey.close()
    try:
      ui.state.saveSettings()
    except CatchableError:
      discard
    event.window.dispose()

  ui.updateDefaultOutputDir()
  ui.pollTimer = startRepeatingTimer(500, proc(event: TimerEvent) =
    # Repaint live recording indicators on a steady cadence.
    if ui.recorder.isRunning() and not ui.recorder.isPaused() and ui.state.duration > 0 and
        ui.activeRecordingSeconds() >= ui.state.duration:
      ui.stopRecordingFlow()
      return

    if ui.recorder.isRunning() and not ui.recorder.isPaused():
      ui.recordingBlinkOn = not ui.recordingBlinkOn
    else:
      ui.recordingBlinkOn = true

    ui.updateButtons()
  )

  ui.hotkeyTimer = startRepeatingTimer(100, proc(event: TimerEvent) =
    if ui.hotkey == nil:
      return
    let action = ui.hotkey.pollAction()
    if action != HotkeyNone:
      ui.handleHotkeyAction(action)
  )

  ui.syncFieldsFromState()
  if ui.state.webcamEnabled:
    ui.refreshWebcamWindow()
  result = ui
