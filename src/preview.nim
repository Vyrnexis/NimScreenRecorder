import math
import os
import osproc

import nigui

import ffmpeg_builder
import state

const
  PreviewRefreshMs = 2000
  DragRefreshMs = 16
  EdgeTolerancePx = 10
  HandleSizePx = 8

type
  DragMode = enum
    DragNone
    DragMove
    DragLeft
    DragRight
    DragTop
    DragBottom
    DragTopLeft
    DragTopRight
    DragBottomLeft
    DragBottomRight

  PreviewGeometry = object
    offsetX: int
    offsetY: int
    drawWidth: int
    drawHeight: int
    scale: float

  DesktopPreview* = ref object of ControlImpl
    state*: RecorderState
    previewImage: Image
    snapshotPath: string
    refreshTimer: Timer
    dragTimer: Timer
    dragMode: DragMode
    dragStartMouseX: int
    dragStartMouseY: int
    dragStartRectX: int
    dragStartRectY: int
    dragStartRectWidth: int
    dragStartRectHeight: int
    onSelectionChanged*: proc()
    lastSnapshotError: string

proc clampInt(value, minValue, maxValue: int): int =
  if value < minValue:
    return minValue
  if value > maxValue:
    return maxValue
  value

proc stopTimer(timer: var Timer) =
  if timer.int != inactiveTimer:
    timer.stop()
    timer = Timer(inactiveTimer)

proc previewGeometry(preview: DesktopPreview): PreviewGeometry =
  if preview.state.desktopWidth <= 0 or preview.state.desktopHeight <= 0 or
      preview.width <= 0 or preview.height <= 0:
    return

  result.scale = min(
    preview.width.float / preview.state.desktopWidth.float,
    preview.height.float / preview.state.desktopHeight.float
  )
  result.drawWidth = max(1, int(round(preview.state.desktopWidth.float * result.scale)))
  result.drawHeight = max(1, int(round(preview.state.desktopHeight.float * result.scale)))
  result.offsetX = (preview.width - result.drawWidth) div 2
  result.offsetY = (preview.height - result.drawHeight) div 2

proc controlPointToReal(preview: DesktopPreview, controlX, controlY: int): tuple[x, y: int] =
  let geometry = preview.previewGeometry()
  if geometry.scale <= 0:
    return (0, 0)

  let localX = clampInt(controlX - geometry.offsetX, 0, geometry.drawWidth)
  let localY = clampInt(controlY - geometry.offsetY, 0, geometry.drawHeight)
  result.x = clampInt(int(round(localX.float / geometry.scale)), 0, preview.state.desktopWidth)
  result.y = clampInt(int(round(localY.float / geometry.scale)), 0, preview.state.desktopHeight)

proc selectionRect(preview: DesktopPreview, geometry: PreviewGeometry): tuple[x, y, width, height: int] =
  result.x = geometry.offsetX + int(round(preview.state.posX.float * geometry.scale))
  result.y = geometry.offsetY + int(round(preview.state.posY.float * geometry.scale))
  result.width = max(2, int(round(preview.state.width.float * geometry.scale)))
  result.height = max(2, int(round(preview.state.height.float * geometry.scale)))

proc notifySelectionChanged(preview: DesktopPreview) =
  if preview.onSelectionChanged != nil:
    preview.onSelectionChanged()
  preview.forceRedraw()

proc hitTest(preview: DesktopPreview, x, y: int): DragMode =
  let geometry = preview.previewGeometry()
  if geometry.scale <= 0:
    return DragNone

  let rect = preview.selectionRect(geometry)
  let nearLeft = abs(x - rect.x) <= EdgeTolerancePx
  let nearRight = abs(x - (rect.x + rect.width)) <= EdgeTolerancePx
  let nearTop = abs(y - rect.y) <= EdgeTolerancePx
  let nearBottom = abs(y - (rect.y + rect.height)) <= EdgeTolerancePx
  let insideRect = x >= rect.x and x <= rect.x + rect.width and y >= rect.y and y <= rect.y + rect.height

  if nearLeft and nearTop: return DragTopLeft
  if nearRight and nearTop: return DragTopRight
  if nearLeft and nearBottom: return DragBottomLeft
  if nearRight and nearBottom: return DragBottomRight
  if nearLeft and insideRect: return DragLeft
  if nearRight and insideRect: return DragRight
  if nearTop and insideRect: return DragTop
  if nearBottom and insideRect: return DragBottom
  if insideRect: return DragMove
  DragNone

proc captureSnapshot(preview: DesktopPreview) =
  if preview.state.desktopWidth <= 0 or preview.state.desktopHeight <= 0:
    return

  var process: Process
  try:
    process = startProcess(
      "ffmpeg",
      args = preview.state.buildSnapshotArgs(preview.snapshotPath),
      options = {poUsePath}
    )
    let exitCode = process.waitForExit()
    process.close()
    process = nil

    if exitCode == 0 and fileExists(preview.snapshotPath):
      if preview.previewImage.isNil:
        preview.previewImage = newImage()
      preview.previewImage.loadFromFile(preview.snapshotPath)
      preview.lastSnapshotError = ""
    else:
      preview.lastSnapshotError = "Preview refresh failed."
  except CatchableError:
    if process != nil:
      process.close()
    preview.lastSnapshotError = getCurrentExceptionMsg()

  preview.forceRedraw()

proc updateDrag(preview: DesktopPreview) =
  if preview.dragMode == DragNone:
    return

  let current = preview.mousePosition()
  let startReal = preview.controlPointToReal(preview.dragStartMouseX, preview.dragStartMouseY)
  let currentReal = preview.controlPointToReal(current.x, current.y)
  let dx = currentReal.x - startReal.x
  let dy = currentReal.y - startReal.y

  var x = preview.dragStartRectX
  var y = preview.dragStartRectY
  var width = preview.dragStartRectWidth
  var height = preview.dragStartRectHeight

  case preview.dragMode
  of DragMove:
    x += dx
    y += dy
  of DragLeft:
    x += dx
    width -= dx
  of DragRight:
    width += dx
  of DragTop:
    y += dy
    height -= dy
  of DragBottom:
    height += dy
  of DragTopLeft:
    x += dx
    width -= dx
    y += dy
    height -= dy
  of DragTopRight:
    width += dx
    y += dy
    height -= dy
  of DragBottomLeft:
    x += dx
    width -= dx
    height += dy
  of DragBottomRight:
    width += dx
    height += dy
  of DragNone:
    discard

  preview.state.setCaptureRect(x, y, width, height)
  preview.notifySelectionChanged()

proc refreshTimerTick(event: TimerEvent) =
  let preview = cast[DesktopPreview](event.data)
  if preview != nil:
    preview.captureSnapshot()

proc dragTimerTick(event: TimerEvent) =
  let preview = cast[DesktopPreview](event.data)
  if preview != nil:
    preview.updateDrag()

proc stopPreview*(preview: DesktopPreview) =
  preview.refreshTimer.stopTimer()
  preview.dragTimer.stopTimer()

proc refreshPreview*(preview: DesktopPreview) =
  preview.captureSnapshot()

method handleDrawEvent(preview: DesktopPreview, event: DrawEvent) =
  let canvas = event.control.canvas
  canvas.areaColor = rgb(24, 24, 28)
  canvas.fill()

  let geometry = preview.previewGeometry()
  if geometry.scale > 0:
    canvas.areaColor = rgb(14, 14, 18)
    canvas.drawRectArea(geometry.offsetX, geometry.offsetY, geometry.drawWidth, geometry.drawHeight)

    if preview.previewImage != nil:
      canvas.interpolationMode = InterpolationMode_Bilinear
      canvas.drawImage(preview.previewImage, geometry.offsetX, geometry.offsetY, geometry.drawWidth, geometry.drawHeight)

    let rect = preview.selectionRect(geometry)
    canvas.lineWidth = 2
    canvas.areaColor = rgb(255, 64, 64, 45)
    canvas.drawRectArea(rect.x, rect.y, rect.width, rect.height)
    canvas.lineColor = rgb(255, 90, 90)
    canvas.drawRectOutline(rect.x, rect.y, rect.width, rect.height)

    for point in @[
      (rect.x, rect.y),
      (rect.x + rect.width, rect.y),
      (rect.x, rect.y + rect.height),
      (rect.x + rect.width, rect.y + rect.height)
    ]:
      canvas.areaColor = rgb(255, 255, 255)
      canvas.drawRectArea(
        point[0] - HandleSizePx div 2,
        point[1] - HandleSizePx div 2,
        HandleSizePx,
        HandleSizePx
      )

    canvas.textColor = rgb(255, 255, 255)
    canvas.fontSize = 13
    canvas.drawText(
      $preview.state.width & "x" & $preview.state.height &
        " @ " & $preview.state.posX & "," & $preview.state.posY,
      geometry.offsetX + 8,
      geometry.offsetY + 8
    )

  if preview.previewImage.isNil:
    canvas.textColor = rgb(220, 220, 220)
    canvas.fontSize = 14
    let message =
      if preview.lastSnapshotError.len > 0:
        "Preview unavailable: " & preview.lastSnapshotError
      else:
        "Refreshing desktop preview..."
    canvas.drawTextCentered(message)

method handleMouseButtonDownEvent(preview: DesktopPreview, event: MouseEvent) =
  procCall preview.ControlImpl.handleMouseButtonDownEvent(event)
  if event.button != MouseButton_Left:
    return

  preview.dragMode = preview.hitTest(event.x, event.y)
  if preview.dragMode == DragNone:
    return

  preview.dragStartMouseX = event.x
  preview.dragStartMouseY = event.y
  preview.dragStartRectX = preview.state.posX
  preview.dragStartRectY = preview.state.posY
  preview.dragStartRectWidth = preview.state.width
  preview.dragStartRectHeight = preview.state.height
  preview.dragTimer.stopTimer()
  preview.dragTimer = startRepeatingTimer(DragRefreshMs, dragTimerTick, cast[pointer](preview))

method handleMouseButtonUpEvent(preview: DesktopPreview, event: MouseEvent) =
  procCall preview.ControlImpl.handleMouseButtonUpEvent(event)
  if event.button == MouseButton_Left:
    preview.dragMode = DragNone
    preview.dragTimer.stopTimer()

proc newDesktopPreview*(state: RecorderState, onSelectionChanged: proc() = nil): DesktopPreview =
  result = new DesktopPreview
  result.init()
  result.state = state
  result.onSelectionChanged = onSelectionChanged
  result.widthMode = WidthMode_Expand
  result.heightMode = HeightMode_Expand
  result.minWidth = 480.scaleToDpi
  result.minHeight = 320.scaleToDpi
  result.snapshotPath = getTempDir() / "nim_screen_recorder_preview.png"
  result.refreshTimer = startRepeatingTimer(PreviewRefreshMs, refreshTimerTick, cast[pointer](result))
  result.onDispose = proc(event: ControlDisposeEvent) =
    let preview = cast[DesktopPreview](event.control)
    preview.stopPreview()
    if fileExists(preview.snapshotPath):
      removeFile(preview.snapshotPath)
  result.captureSnapshot()
