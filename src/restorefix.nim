import nigui

# Platform-specific top-level window restore used after recording stops.

when not defined(windows):
  import nigui/private/gtk3/gtk3

  const
    gtkLib = "libgtk-3.so.0"
    gdkLib = "libgdk-3.so.0"
    x11Lib = "libX11.so.6"
    SubstructureNotifyMask = clong(1) shl 19
    SubstructureRedirectMask = clong(1) shl 20
    ClientMessage = 33

  type
    GtkWindowShim = ref object of Window
      fHandle: pointer

    XClientMessageData = object
      l: array[5, clong]

    XClientMessageEvent = object
      kind: cint
      serial: culong
      send_event: cint
      display: pointer
      window: culong
      message_type: culong
      format: cint
      data: XClientMessageData

  proc gtk_widget_get_window(widget: pointer): pointer {.cdecl, importc, dynlib: gtkLib.}
  proc gtk_window_present_with_time(window: pointer, timestamp: uint32) {.cdecl, importc, dynlib: gtkLib.}
  proc gdk_display_get_default(): pointer {.cdecl, importc, dynlib: gdkLib.}
  proc gdk_x11_display_get_xdisplay(display: pointer): pointer {.cdecl, importc, dynlib: gdkLib.}
  proc gdk_x11_window_get_xid(window: pointer): culong {.cdecl, importc, dynlib: gdkLib.}
  proc XDefaultRootWindow(display: pointer): culong {.cdecl, importc, dynlib: x11Lib.}
  proc XInternAtom(display: pointer, atomName: cstring, onlyIfExists: cint): culong {.cdecl, importc, dynlib: x11Lib.}
  proc XSendEvent(display: pointer, window: culong, propagate: cint, eventMask: clong,
    eventSend: pointer): cint {.cdecl, importc, dynlib: x11Lib.}
  proc XMapRaised(display: pointer, window: culong): cint {.cdecl, importc, dynlib: x11Lib.}
  proc XRaiseWindow(display: pointer, window: culong): cint {.cdecl, importc, dynlib: x11Lib.}
  proc XFlush(display: pointer): cint {.cdecl, importc, dynlib: x11Lib.}

proc restoreWindow*(window: Window) =
  # Budgie sometimes ignores NiGui's generic restore after a global hotkey stop,
  # so on X11 we also send the native GTK and EWMH activation requests.
  if window == nil:
    return

  when not defined(windows):
    let handle = cast[GtkWindowShim](window).fHandle
    if handle == nil:
      return

    gtk_window_deiconify(handle)
    gtk_window_present_with_time(handle, 0'u32)
    gtk_window_present(handle)

    let gdkWindow = gtk_widget_get_window(handle)
    let gdkDisplay = gdk_display_get_default()
    if gdkWindow == nil or gdkDisplay == nil:
      return

    let xDisplay = gdk_x11_display_get_xdisplay(gdkDisplay)
    let xWindow = gdk_x11_window_get_xid(gdkWindow)
    if xDisplay == nil or xWindow == 0:
      return

    let rootWindow = XDefaultRootWindow(xDisplay)
    let activeWindowAtom = XInternAtom(xDisplay, "_NET_ACTIVE_WINDOW", 0)
    if rootWindow != 0 and activeWindowAtom != 0:
      var event = XClientMessageEvent(
        kind: ClientMessage,
        send_event: 1,
        display: xDisplay,
        window: xWindow,
        message_type: activeWindowAtom,
        format: 32
      )
      event.data.l[0] = 1
      event.data.l[1] = 0
      discard XSendEvent(
        xDisplay,
        rootWindow,
        0,
        SubstructureNotifyMask or SubstructureRedirectMask,
        addr event
      )

    discard XMapRaised(xDisplay, xWindow)
    discard XRaiseWindow(xDisplay, xWindow)
    discard XFlush(xDisplay)
  else:
    window.visible = true
