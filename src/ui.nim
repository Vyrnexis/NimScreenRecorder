import strutils

import nigui

import preview
import recorder
import state

type
  RecorderUi* = ref object
    window*: Window
    state*: RecorderState
    recorder*: Recorder
    preview*: DesktopPreview
    pollTimer: Timer
    syncingFields: bool
    outputDirCustomized: bool
    projectNameBox: TextBox
    outputDirBox: TextBox
    presetCombo: ComboBox
    widthBox: TextBox
    heightBox: TextBox
    xBox: TextBox
    yBox: TextBox
    fpsCombo: ComboBox
    durationBox: TextBox
    audioCombo: ComboBox
    startButton: Button
    stopButton: Button
    statusLabel: Label

proc stopTimer(timer: var Timer) =
  if timer.int != inactiveTimer:
    timer.stop()
    timer = Timer(inactiveTimer)

proc tryParseInt(text: string, value: var int): bool =
  try:
    value = text.strip().parseInt()
    true
  except ValueError:
    false

proc newFormRow(labelText: string, control: Control): LayoutContainer =
  result = newLayoutContainer(Layout_Horizontal)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Auto
  result.spacing = 8
  result.yAlign = YAlign_Center

  let label = newLabel(labelText)
  label.width = 104.scaleToDpi
  label.xTextAlign = XTextAlign_Right
  label.yTextAlign = YTextAlign_Center
  result.add(label)

  control.widthMode = WidthMode_Expand
  result.add(control)

proc newCompactField(labelText: string, control: Control): LayoutContainer =
  result = newLayoutContainer(Layout_Horizontal)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Auto
  result.spacing = 6
  result.yAlign = YAlign_Center

  let label = newLabel(labelText)
  label.width = 54.scaleToDpi
  label.xTextAlign = XTextAlign_Right
  label.yTextAlign = YTextAlign_Center
  result.add(label)

  control.widthMode = WidthMode_Expand
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

proc newSectionTitle(text: string): Label =
  result = newLabel("  " & text)
  result.fontBold = true
  result.fontSize = 17
  result.widthMode = WidthMode_Expand
  result.height = 30.scaleToDpi
  result.xTextAlign = XTextAlign_Left
  result.yTextAlign = YTextAlign_Center
  result.textColor = rgb(255, 255, 255)
  result.backgroundColor = rgb(70, 92, 128)

proc newFieldHeader(text: string): Label =
  result = newLabel(text)
  result.fontBold = true
  result.widthMode = WidthMode_Expand
  result.textColor = rgb(70, 70, 82)

proc styleSection(container: LayoutContainer) =
  container.padding = 10
  container.spacing = 10
  container.backgroundColor = rgb(248, 249, 252)

proc updateDefaultOutputDir(ui: RecorderUi) =
  if ui.outputDirCustomized:
    return
  ui.state.outputDir = defaultOutputDir(ui.state.projectName)
  if ui.outputDirBox != nil:
    ui.outputDirBox.text = ui.state.outputDir

proc updateButtons(ui: RecorderUi) =
  let running = ui.recorder.isRunning()
  ui.state.isRecording = running
  ui.startButton.enabled = not running
  ui.stopButton.enabled = running
  if running:
    ui.statusLabel.text = "Recording: " & ui.recorder.currentOutput
  else:
    ui.statusLabel.text = "Idle"

proc syncFieldsFromState(ui: RecorderUi) =
  ui.syncingFields = true
  defer:
    ui.syncingFields = false

  ui.projectNameBox.text = ui.state.projectName
  ui.outputDirBox.text = ui.state.outputDir
  ui.presetCombo.value = ui.state.preset
  ui.widthBox.text = $ui.state.width
  ui.heightBox.text = $ui.state.height
  ui.xBox.text = $ui.state.posX
  ui.yBox.text = $ui.state.posY
  ui.fpsCombo.value = $ui.state.fps
  ui.durationBox.text = $ui.state.duration
  ui.audioCombo.value = ui.state.audioSource
  ui.updateButtons()

proc handlePreviewChanged(ui: RecorderUi) =
  ui.syncFieldsFromState()

proc buildProjectSettings(ui: RecorderUi): LayoutContainer =
  result = newLayoutContainer(Layout_Vertical)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Auto
  result.styleSection()
  result.add(newSectionTitle("Project Settings"))

  ui.projectNameBox = newTextBox(ui.state.projectName)
  ui.projectNameBox.placeholder = "Untitled project"
  ui.projectNameBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    ui.state.projectName = ui.projectNameBox.text
    ui.updateDefaultOutputDir()
  result.add(newFormRow("Project name", ui.projectNameBox))

  ui.outputDirBox = newTextBox(ui.state.outputDir)
  ui.outputDirBox.placeholder = defaultOutputDir("")
  ui.outputDirBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    ui.state.outputDir = ui.outputDirBox.text
    ui.outputDirCustomized = ui.outputDirBox.text.strip().len > 0 and
      ui.outputDirBox.text != defaultOutputDir(ui.state.projectName)

  let browseButton = newButton("Browse")
  browseButton.onClick = proc(event: ClickEvent) =
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
  browseButton.width = 92.scaleToDpi
  folderRow.add(browseButton)
  folderField.add(folderRow)
  result.add(folderField)

proc buildCaptureSettings(ui: RecorderUi): LayoutContainer =
  result = newLayoutContainer(Layout_Vertical)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Auto
  result.styleSection()
  result.add(newSectionTitle("Capture Settings"))

  ui.presetCombo = newComboBox(ResolutionPresetOptions)
  ui.presetCombo.minWidth = 180.scaleToDpi
  ui.presetCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    ui.state.applyPreset(ui.presetCombo.value)
    ui.syncFieldsFromState()
    ui.preview.forceRedraw()
  result.add(newFormRow("Preset", ui.presetCombo))

  ui.widthBox = newTextBox($ui.state.width)
  ui.widthBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.widthBox.text, value):
      ui.state.setCaptureSize(value, ui.state.height)
      ui.handlePreviewChanged()

  ui.heightBox = newTextBox($ui.state.height)
  ui.heightBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.heightBox.text, value):
      ui.state.setCaptureSize(ui.state.width, value)
      ui.handlePreviewChanged()
  result.add(newPairedRow("Width", ui.widthBox, "Height", ui.heightBox))

  ui.xBox = newTextBox($ui.state.posX)
  ui.xBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.xBox.text, value):
      ui.state.setCapturePosition(value, ui.state.posY)
      ui.handlePreviewChanged()

  ui.yBox = newTextBox($ui.state.posY)
  ui.yBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.yBox.text, value):
      ui.state.setCapturePosition(ui.state.posX, value)
      ui.handlePreviewChanged()
  result.add(newPairedRow("X", ui.xBox, "Y", ui.yBox))

proc buildRecordingSettings(ui: RecorderUi): LayoutContainer =
  result = newLayoutContainer(Layout_Vertical)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Auto
  result.styleSection()
  result.add(newSectionTitle("Recording Settings"))

  ui.fpsCombo = newComboBox(FpsOptions)
  ui.fpsCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.fpsCombo.value, value):
      ui.state.fps = value

  ui.durationBox = newTextBox($ui.state.duration)
  ui.durationBox.onTextChange = proc(event: TextChangeEvent) =
    if ui.syncingFields:
      return
    var value: int
    if tryParseInt(ui.durationBox.text, value):
      ui.state.duration = max(0, value)
  result.add(newPairedRow("FPS", ui.fpsCombo, "Seconds", ui.durationBox))

  let audioOptions = detectAudioSources()
  ui.audioCombo = newComboBox(audioOptions)
  if ui.state.audioSource notin audioOptions:
    ui.state.audioSource = NoAudioSource
  ui.audioCombo.onChange = proc(event: ComboBoxChangeEvent) =
    if ui.syncingFields:
      return
    ui.state.audioSource = ui.audioCombo.value
  result.add(newFormRow("Audio source", ui.audioCombo))

proc buildButtons(ui: RecorderUi): LayoutContainer =
  result = newLayoutContainer(Layout_Vertical)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Auto
  result.spacing = 8
  result.padding = 2

  let buttonRow = newLayoutContainer(Layout_Horizontal)
  buttonRow.widthMode = WidthMode_Expand
  buttonRow.heightMode = HeightMode_Auto
  buttonRow.spacing = 8

  ui.startButton = newButton("Start Recording")
  ui.startButton.widthMode = WidthMode_Expand
  ui.startButton.minWidth = 150.scaleToDpi
  ui.startButton.onClick = proc(event: ClickEvent) =
    try:
      discard ui.recorder.startRecording(ui.state)
      ui.updateButtons()
    except CatchableError:
      alert(ui.window, getCurrentExceptionMsg(), "Start Recording Failed")
  buttonRow.add(ui.startButton)

  ui.stopButton = newButton("Stop Recording")
  ui.stopButton.widthMode = WidthMode_Expand
  ui.stopButton.minWidth = 150.scaleToDpi
  ui.stopButton.onClick = proc(event: ClickEvent) =
    ui.recorder.stopRecording(ui.state)
    ui.updateButtons()
  buttonRow.add(ui.stopButton)
  result.add(buttonRow)

proc buildPreviewPanel(ui: RecorderUi): LayoutContainer =
  result = newLayoutContainer(Layout_Vertical)
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Expand
  result.styleSection()
  result.add(newSectionTitle("Preview Panel"))

  ui.preview = newDesktopPreview(ui.state, proc() = ui.handlePreviewChanged())
  result.add(ui.preview)

  let hint = newLabel("Drag inside the red rectangle to move it. Drag an edge or corner to resize.")
  hint.widthMode = WidthMode_Expand
  hint.textColor = rgb(92, 92, 104)
  result.add(hint)

proc newRecorderUi*(): RecorderUi =
  let ui = RecorderUi(
    state: newRecorderState(),
    recorder: newRecorder()
  )

  ui.window = newWindow("Nim Screen Recorder")
  ui.window.width = 1200.scaleToDpi
  ui.window.height = 760.scaleToDpi
  ui.window.minWidth = 980.scaleToDpi
  ui.window.minHeight = 640.scaleToDpi

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
  sidebar.width = 430.scaleToDpi
  sidebar.heightMode = HeightMode_Expand
  sidebar.spacing = 12
  sidebar.backgroundColor = rgb(232, 235, 240)

  let projectSection = ui.buildProjectSettings()
  projectSection.widthMode = WidthMode_Expand

  let captureSection = ui.buildCaptureSettings()
  captureSection.widthMode = WidthMode_Expand

  let recordingSection = ui.buildRecordingSettings()
  recordingSection.widthMode = WidthMode_Expand

  let actionSection = ui.buildButtons()
  actionSection.widthMode = WidthMode_Expand

  sidebar.add(projectSection)
  sidebar.add(captureSection)
  sidebar.add(recordingSection)
  sidebar.add(actionSection)

  let previewPanel = ui.buildPreviewPanel()
  previewPanel.widthMode = WidthMode_Expand
  previewPanel.heightMode = HeightMode_Expand

  mainRow.add(sidebar)
  mainRow.add(previewPanel)
  root.add(mainRow)

  let statusBar = newLayoutContainer(Layout_Horizontal)
  statusBar.widthMode = WidthMode_Expand
  statusBar.heightMode = HeightMode_Auto
  statusBar.spacing = 12
  statusBar.padding = 8
  statusBar.yAlign = YAlign_Center
  statusBar.backgroundColor = rgb(216, 220, 227)

  ui.statusLabel = newLabel("Idle")
  ui.statusLabel.fontBold = true
  ui.statusLabel.textColor = rgb(46, 76, 124)
  ui.statusLabel.widthMode = WidthMode_Expand
  ui.statusLabel.yTextAlign = YTextAlign_Center
  statusBar.add(ui.statusLabel)

  let desktopInfo = newLabel(
    "Desktop: " & $ui.state.desktopWidth & "x" & $ui.state.desktopHeight &
      " on " & ui.state.display
  )
  desktopInfo.textColor = rgb(92, 92, 104)
  desktopInfo.yTextAlign = YTextAlign_Center
  statusBar.add(desktopInfo)

  root.add(statusBar)
  ui.window.add(root)

  ui.window.onCloseClick = proc(event: CloseClickEvent) =
    ui.pollTimer.stopTimer()
    ui.preview.stopPreview()
    ui.recorder.stopRecording(ui.state)
    event.window.dispose()

  ui.updateDefaultOutputDir()
  ui.pollTimer = startRepeatingTimer(500, proc(event: TimerEvent) =
    ui.updateButtons()
  )

  ui.syncFieldsFromState()
  result = ui
