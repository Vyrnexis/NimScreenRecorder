import times

# Global X11 hotkey support for start/stop recording.

const
  x11Lib = "libX11.so.6"
  HotkeyDescription* = "Ctrl+Alt+R"
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

  XEvent {.union, bycopy.} = object
    kind: cint
    padding: array[24, clong]

  GlobalHotkeyController* = ref object
    display: DisplayHandle
    rootWindow: WindowId
    keycode: cint
    lastTriggerAt: float
    keyDown: bool

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

proc grabModifiers(): array[4, cuint] =
  [
    ControlMask or Mod1Mask,
    ControlMask or Mod1Mask or LockMask,
    ControlMask or Mod1Mask or Mod2Mask,
    ControlMask or Mod1Mask or LockMask or Mod2Mask
  ]

proc newGlobalHotkeyController*(): GlobalHotkeyController =
  let display = XOpenDisplay(nil)
  if display.isNil:
    return GlobalHotkeyController()

  let keysym = XStringToKeysym("r")
  if keysym == 0:
    discard XCloseDisplay(display)
    return GlobalHotkeyController()

  let keycode = cint(XKeysymToKeycode(display, keysym))
  if keycode == 0:
    discard XCloseDisplay(display)
    return GlobalHotkeyController()

  let rootWindow = XRootWindow(display, XDefaultScreen(display))
  for modifiers in grabModifiers():
    discard XGrabKey(display, keycode, modifiers, rootWindow, 0, GrabModeAsync, GrabModeAsync)
  discard XSync(display, 0)

  GlobalHotkeyController(
    display: display,
    rootWindow: rootWindow,
    keycode: keycode
  )

proc available*(controller: GlobalHotkeyController): bool =
  controller != nil and not controller.display.isNil and controller.keycode != 0

proc close*(controller: GlobalHotkeyController) =
  if not controller.available():
    return

  for modifiers in grabModifiers():
    discard XUngrabKey(controller.display, controller.keycode, modifiers, controller.rootWindow)
  discard XSync(controller.display, 0)
  discard XCloseDisplay(controller.display)
  controller.display = nil
  controller.keycode = 0

proc pollTriggered*(controller: GlobalHotkeyController): bool =
  # Treat the global hotkey as an edge-triggered press so key repeat does not
  # toggle start/stop multiple times while the chord is still held down.
  if not controller.available():
    return false

  var event: XEvent
  while XPending(controller.display) > 0:
    discard XNextEvent(controller.display, addr event)
    case event.kind
    of KeyPress:
      if controller.keyDown:
        continue

      controller.keyDown = true
      let nowSeconds = epochTime()
      if nowSeconds - controller.lastTriggerAt >= 0.5:
        controller.lastTriggerAt = nowSeconds
        result = true
    of KeyRelease:
      controller.keyDown = false
    else:
      discard
