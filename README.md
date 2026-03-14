# Nim Screen Recorder

Linux desktop screen recorder for X11 written in Nim with NiGui and FFmpeg.

It provides a desktop preview inside the main window, region and window capture modes, optional webcam-window support, and an FFmpeg-based recording backend.

## Screenshot

![Nim Screen Recorder main window](assets/screenshot-main.png)

## Features

- Desktop preview panel with a draggable and resizable capture rectangle
- Settings are restored between launches
- Project settings for project name and output folder
- Built-in recording profiles for tutorial, shorts, and demo workflows
- Capture settings for region or window mode, presets, width, height, X, Y, selected window, and aspect-ratio feedback
- Recording settings for FPS, duration, countdown, audio source, encoder, output format, quality, and optional auto-hide
- Configurable global hotkeys using `Ctrl+Alt+<Key>` for record and pause
- Optional webcam window driven by `ffplay`
- FFmpeg subprocess backend for X11 screen capture
- Clean recorder shutdown so recordings finalize correctly
- Pause/resume support for active recordings without keeping a frozen paused section
- Idle, recording, and paused application icons for clearer taskbar feedback
- Desktop notifications for start, pause, resume, stop, and failure while the app is minimized
- Preview countdown overlay before recording begins
- Per-recording FFmpeg log files when a recording fails unexpectedly
- History actions for opening the latest recording, copying paths, and opening the last FFmpeg log
- Recent recordings history in the `History` section
- Optional MKV-to-MP4 remux after recording stops

## Build Requirements

- Nim 2.2+
- NiGui

## Runtime Dependencies

Required for the compiled app:

- `ffmpeg`
- GTK3 runtime libraries
- Linux desktop session
- X11 display

Optional, depending on features:

- `ffplay` for the webcam window feature
- `xdotool` for `Window` capture mode
- `notify-send` for desktop notifications
- `pactl` for audio-source discovery
- `xdg-open` for `Open Folder`

The app still works for basic region recording if optional tools are missing, but the related features will not.
Unavailable optional features are disabled in the UI automatically.

## Build

Run directly with Nim:

```bash
nim c -r src/NimScreenRecorder.nim
```

Release build:

```bash
nim c -d:release -r src/NimScreenRecorder.nim
```

Nimble tasks:

```bash
nimble Debug
nimble Release
nimble ReleasePortable
```

All Nimble tasks place the binary in `./bin`.

- `Release`: normal local release build using compiler defaults
- `ReleasePortable`: portable x86-64 release build for wider Linux compatibility

## Install

For a compiled release tree, install the app user-local with:

```bash
./install-user.sh
```

That installs:

- the binary into `~/.local/bin`
- the desktop launcher into `~/.local/share/applications`
- the icons into `~/.local/share/icons/hicolor`

Run the install script again after icon or desktop-file changes so the launcher metadata is refreshed.

Remove the user-local install with:

```bash
./uninstall-user.sh
```

Compiled releases do not require Nim or Nimble to run.

## How To Use

1. Start the app.
2. Set a project name if you want named output files.
3. Choose or browse to an output folder.
4. Pick a profile if you want a quick starting point:
   - `Tutorial`
   - `Shorts`
   - `Demo`
   Manual edits automatically switch back to `Custom`.
5. Choose a capture mode:
   - `Region`: use the preview panel or the X/Y/Width/Height fields.
   - `Window`: click `Pick Window`, then click the X11 window you want to record.
6. Choose recording settings:
   - FPS
   - duration
   - countdown
   - audio source
   - refresh audio sources if needed
   - encoder
   - format
   - optional MKV-to-MP4 remux
   - quality
7. If you want the webcam visible in the recording, stay in `Region` mode and enable `Show webcam window`.
8. Choose the record and pause hotkey keys in `Recording Settings` if you do not want the defaults.
9. Start recording with the button or the configured `Ctrl+Alt+<Record Key>` hotkey.
10. If a countdown is enabled, the preview panel shows a countdown overlay before recording starts.
11. Pause or resume with the `Pause Recording` button or the configured `Ctrl+Alt+<Pause Key>` hotkey.
12. Stop recording with the button or the configured record hotkey.
13. Use the `History` section after a recording finishes:
   `Open Latest`, `Copy Latest Path`, `Open Selected`, `Copy Selected Path`, or `Open Last Log`.

## Capture Modes

`Region`

- The preview panel is editable.
- You can drag and resize the capture rectangle.
- Webcam window support is available.

`Window`

- The selected X11 window is recorded directly with `-window_id`.
- Preview editing is locked to the selected window bounds.
- Window bounds are refreshed automatically before recording starts.
- If the selected window is gone, the selection is cleared and you are prompted to pick again.
- Use `Refresh Bounds` if the target window moves or resizes before recording.
- Webcam window support is disabled in this mode because the webcam is a separate window.
- If `xdotool` is missing, window capture is unavailable and the UI stays in `Region` mode.

## Encoders

`libx264`

- software encoder
- best compatibility
- higher CPU usage

`VAAPI`

- hardware encoder for supported Linux GPU stacks
- lower CPU usage
- often better for high-resolution or high-FPS recording

`NVENC`

- hardware encoder for NVIDIA GPUs
- only shown when supported by both FFmpeg and local hardware

## Webcam Window

The webcam is not composited into FFmpeg.

When `Show webcam window` is enabled:

- the app launches a separate webcam window with `ffplay`
- the webcam can be mirrored
- you place that window inside the recording area
- the desktop recording captures it like any other window

This keeps recording smoother than live FFmpeg webcam compositing.

If `ffplay` is missing, the webcam controls stay disabled and the app continues to work without the webcam feature.

## Project Structure

- `src/NimScreenRecorder.nim`: binary entrypoint
- `src/ui.nim`: window layout and UI bindings
- `src/state.nim`: recorder state, presets, validation, and environment detection
- `src/preview.nim`: desktop preview widget and region selection logic
- `src/ffmpeg.nim`: FFmpeg argument generation for screen recording
- `src/recorder.nim`: FFmpeg recording subprocess lifecycle
- `src/restorefix.nim`: Linux/X11 window restore workaround for global-hotkey stop
- `src/windowpicker.nim`: X11 window selection and geometry lookup via `xdotool`
- `src/webcam.nim`: webcam device detection and `ffplay` window lifecycle

## Notes

- Preview refreshes by capturing desktop screenshots with FFmpeg.
- Default output directory is `~/Videos/<Project Name>`.
- If the project name is blank, the output file name falls back to a timestamp.
- Output folder paths are normalized before recording.
- Most settings are saved to `~/.config/NimScreenRecorder/settings.json` and restored on the next launch.
- Encoder choices are limited to what the local FFmpeg build and hardware can actually use.
- Recording format can be switched between `MP4` and `MKV`.
- The default output format is `MKV` because it is safer if a recording stops unexpectedly.
- If `Remux MKV to MP4 after stop` is enabled, the app keeps the MKV recording and also creates an MP4 copy.
- Quality presets map to simple defaults for the selected encoder: `Fast`, `Balanced`, and `High`.
- `Hide app window while recording` minimizes the app and restores it again when recording stops.
- Pausing closes the current recording segment and resuming starts a new one.
- The final output is assembled from those segments, so paused time is skipped instead of appearing as a frozen section.
- The window icon changes between idle, recording, and paused states when the desktop honors runtime icon updates.
- When `Hide app window while recording` is enabled, desktop notifications provide state feedback even if the taskbar icon does not change live.
- If FFmpeg exits unexpectedly, the app shows the failure and stores a `.ffmpeg.log` file next to the intended output file.
- If `ffplay` or `xdotool` are missing, the related webcam or window-capture features will not be available.
- The recent recordings list stores the latest completed output paths and keeps the newest entries first.
