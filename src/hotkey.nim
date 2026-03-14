import strutils
import times

# Global X11 hotkey support for recording control actions.

############################
# X11 Constants and Types
############################

const
  x11Lib = "libX11.so.6"
  KeyPress = 2
  KeyRelease = 3
  GrabModeAsync = 1
  ControlMask = 1'u32 shl 2
  LockMask = 1'u32 shl 1
  Mod1Mask = 1'u32 shl 3
  Mod2Mask = 1'u32 shl 4

type
  DisplayHandle = pointer
  WindowId = culong
  KeySym = culong
  KeyCode = uint8
  TimeStamp = culong

  XKeyEvent {.bycopy.} = object
    kind: cint
    serial: culong
    sendEvent: cint
    display: DisplayHandle
    window: WindowId
    root: WindowId
    subwindow: WindowId
    time: TimeStamp
    x: cint
    y: cint
    xRoot: cint
    yRoot: cint
    state: cuint
    keycode: cuint
    sameScreen: cint

  XEvent {.union, bycopy.} = object
    kind: cint
    padding: array[24, culong]

  HotkeyAction* = enum
    HotkeyNone
    HotkeyRecordToggle
    HotkeyPauseToggle

  GlobalHotkeyController* = ref object
    display: DisplayHandle
    rootWindow: WindowId
    recordKeycode: cint
    pauseKeycode: cint
    lastRecordTriggerAt: float
    lastPauseTriggerAt: float
    recordKeyDown: bool
    pauseKeyDown: bool

############################
# X11 Imports
############################

proc XOpenDisplay(name: cstring): DisplayHandle {.cdecl, importc, dynlib: x11Lib.}
proc XCloseDisplay(display: DisplayHandle): cint {.cdecl, importc, dynlib: x11Lib.}
proc XDefaultScreen(display: DisplayHandle): cint {.cdecl, importc, dynlib: x11Lib.}
proc XRootWindow(display: DisplayHandle, screenNumber: cint): WindowId {.cdecl, importc, dynlib: x11Lib.}
proc XStringToKeysym(name: cstring): KeySym {.cdecl, importc, dynlib: x11Lib.}
proc XKeysymToKeycode(display: DisplayHandle, keysym: KeySym): KeyCode {.cdecl, importc, dynlib: x11Lib.}
proc XGrabKey(display: DisplayHandle, keycode: cint, modifiers: cuint, grabWindow: WindowId,
  ownerEvents, pointerMode, keyboardMode: cint): cint {.cdecl, importc, dynlib: x11Lib.}
proc XUngrabKey(display: DisplayHandle, keycode: cint, modifiers: cuint, grabWindow: WindowId): cint {.cdecl, importc, dynlib: x11Lib.}
proc XSync(display: DisplayHandle, discardQueued: cint): cint {.cdecl, importc, dynlib: x11Lib.}
proc XPending(display: DisplayHandle): cint {.cdecl, importc, dynlib: x11Lib.}
proc XNextEvent(display: DisplayHandle, event: ptr XEvent): cint {.cdecl, importc, dynlib: x11Lib.}

############################
# Internal Helpers
############################

proc grabModifiers(): array[4, cuint] =
  [
    ControlMask or Mod1Mask,
    ControlMask or Mod1Mask or LockMask,
    ControlMask or Mod1Mask or Mod2Mask,
    ControlMask or Mod1Mask or LockMask or Mod2Mask
  ]

proc eventKeycode(event: XEvent): cint =
  # Read the grabbed keycode through the native XKeyEvent layout.
  cint(cast[ptr XKeyEvent](unsafeAddr event)[].keycode)

proc keycodeFor(display: DisplayHandle, keyName: string): cint =
  var keysym = XStringToKeysym(keyName.cstring)
  if keysym == 0 and keyName.len == 1:
    keysym = XStringToKeysym(keyName.toLowerAscii().cstring)
  if keysym == 0:
    return 0
  cint(XKeysymToKeycode(display, keysym))

############################
# Public API
############################

proc newGlobalHotkeyController*(recordKeyName, pauseKeyName: string): GlobalHotkeyController =
  let display = XOpenDisplay(nil)
  if display.isNil:
    return GlobalHotkeyController()

  let recordKeycode = keycodeFor(display, recordKeyName)
  let pauseKeycode = keycodeFor(display, pauseKeyName)
  if recordKeycode == 0 or pauseKeycode == 0:
    discard XCloseDisplay(display)
    return GlobalHotkeyController()

  let rootWindow = XRootWindow(display, XDefaultScreen(display))
  for modifiers in grabModifiers():
    discard XGrabKey(display, recordKeycode, modifiers, rootWindow, 0, GrabModeAsync, GrabModeAsync)
    discard XGrabKey(display, pauseKeycode, modifiers, rootWindow, 0, GrabModeAsync, GrabModeAsync)
  discard XSync(display, 0)

  GlobalHotkeyController(
    display: display,
    rootWindow: rootWindow,
    recordKeycode: recordKeycode,
    pauseKeycode: pauseKeycode
  )

proc available*(controller: GlobalHotkeyController): bool =
  controller != nil and not controller.display.isNil and controller.recordKeycode != 0 and controller.pauseKeycode != 0

proc close*(controller: GlobalHotkeyController) =
  if not controller.available():
    return

  for modifiers in grabModifiers():
    discard XUngrabKey(controller.display, controller.recordKeycode, modifiers, controller.rootWindow)
    discard XUngrabKey(controller.display, controller.pauseKeycode, modifiers, controller.rootWindow)
  discard XSync(controller.display, 0)
  discard XCloseDisplay(controller.display)
  controller.display = nil
  controller.recordKeycode = 0
  controller.pauseKeycode = 0
  controller.recordKeyDown = false
  controller.pauseKeyDown = false

proc pollAction*(controller: GlobalHotkeyController): HotkeyAction =
  # Treat the global hotkeys as edge-triggered presses so key repeat does not
  # toggle actions multiple times while the chord is still held down.
  if not controller.available():
    return HotkeyNone

  var event: XEvent
  while XPending(controller.display) > 0:
    discard XNextEvent(controller.display, addr event)
    case event.kind
    of KeyPress:
      let keycode = event.eventKeycode()
      let nowSeconds = epochTime()
      if keycode == controller.recordKeycode:
        if controller.recordKeyDown:
          continue
        controller.recordKeyDown = true
        if nowSeconds - controller.lastRecordTriggerAt >= 0.35:
          controller.lastRecordTriggerAt = nowSeconds
          result = HotkeyRecordToggle
      elif keycode == controller.pauseKeycode:
        if controller.pauseKeyDown:
          continue
        controller.pauseKeyDown = true
        if nowSeconds - controller.lastPauseTriggerAt >= 0.35:
          controller.lastPauseTriggerAt = nowSeconds
          result = HotkeyPauseToggle
    of KeyRelease:
      let keycode = event.eventKeycode()
      if keycode == controller.recordKeycode:
        controller.recordKeyDown = false
      elif keycode == controller.pauseKeycode:
        controller.pauseKeyDown = false
    else:
      discard
