import os
import osproc

import appicon

# Desktop notifications are used when the main window is minimized during recording.

############################
# Notification Settings
############################

const
  NotificationAppName = "Nim Screen Recorder"

############################
# Public API
############################

proc notifyAvailable*(): bool =
  findExe("notify-send").len > 0

proc sendNotification*(title, body: string; iconState = IconStateIdle; urgency = "normal") =
  if not notifyAvailable():
    return

  var args = @["-a", NotificationAppName, "-u", urgency]
  let iconPath = resolveIconPath(iconState)
  if iconPath.len > 0:
    args.add(@["-i", iconPath])
  args.add(title)
  if body.len > 0:
    args.add(body)

  try:
    let process = startProcess(
      "notify-send",
      args = args,
      options = {poUsePath, poDaemon, poStdErrToStdOut}
    )
    process.close()
  except CatchableError:
    discard
