import os
import osproc
import strutils

# X11 window selection helpers built on xdotool.

type
  WindowSelection* = object
    id*: string
    title*: string
    x*: int
    y*: int
    width*: int
    height*: int

proc parseGeometry(output: string): WindowSelection =
  for line in output.splitLines():
    let parts = line.split("=", maxsplit = 1)
    if parts.len != 2:
      continue

    case parts[0]
    of "WINDOW":
      result.id = parts[1].strip()
    of "X":
      result.x = parseInt(parts[1].strip())
    of "Y":
      result.y = parseInt(parts[1].strip())
    of "WIDTH":
      result.width = parseInt(parts[1].strip())
    of "HEIGHT":
      result.height = parseInt(parts[1].strip())
    else:
      discard

proc queryWindow*(windowId: string): WindowSelection =
  if windowId.strip().len == 0:
    raise newException(IOError, "Window ID is empty.")

  let (geometryOutput, geometryExit) = execCmdEx(
    "xdotool getwindowgeometry --shell " & quoteShell(windowId)
  )
  if geometryExit != 0:
    raise newException(IOError, "Could not query the selected window.")

  result = parseGeometry(geometryOutput)
  if result.id.len == 0:
    result.id = windowId.strip()

  let (titleOutput, _) = execCmdEx("xdotool getwindowname " & quoteShell(result.id))
  result.title = titleOutput.strip()
  if result.title.len == 0:
    result.title = "Window " & result.id

proc pickWindow*(): WindowSelection =
  if findExe("xdotool").len == 0:
    raise newException(IOError, "xdotool is not installed or not on PATH.")

  let (windowId, exitCode) = execCmdEx("xdotool selectwindow")
  if exitCode != 0 or windowId.strip().len == 0:
    raise newException(IOError, "Window selection was cancelled.")

  result = queryWindow(windowId.strip())
