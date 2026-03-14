import os

# Shared icon lookup for the main window, notifications, and desktop integration.

############################
# Icon States
############################

const
  IconStateIdle* = "idle"
  IconStateRecording* = "recording"
  IconStatePaused* = "paused"

############################
# Icon Lookup
############################

proc iconBaseName*(state: string): string =
  case state
  of IconStateRecording:
    "NimScreenRecorder-recording"
  of IconStatePaused:
    "NimScreenRecorder-paused"
  else:
    "NimScreenRecorder"

proc resolveIconPath*(state: string): string =
  let appDir = getAppDir()
  let baseName = iconBaseName(state)
  for ext in [".svg", ".png"]:
    let fileName = baseName & ext
    for candidate in @[
      appDir / ".." / "icons" / fileName,
      appDir / "icons" / fileName,
      getHomeDir() / ".local" / "share" / "icons" / "hicolor" / "scalable" / "apps" / fileName,
      getHomeDir() / ".local" / "share" / "icons" / "hicolor" / "256x256" / "apps" / fileName,
      "/usr/local/share/icons/hicolor/scalable/apps/" & fileName,
      "/usr/local/share/icons/hicolor/256x256/apps/" & fileName,
      "/usr/share/icons/hicolor/scalable/apps/" & fileName,
      "/usr/share/icons/hicolor/256x256/apps/" & fileName
    ]:
      let normalized = absolutePath(candidate)
      if fileExists(normalized):
        return normalized
  ""
