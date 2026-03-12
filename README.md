# Nim Screen Recorder

Linux desktop screen recorder prototype written in Nim with NiGui and FFmpeg.

## Features

- Desktop preview panel with a draggable and resizable capture rectangle
- Project settings for project name, output folder, normalized path, and live output-file preview
- Capture settings for region or window mode, presets, width, height, X, Y, selected window, and aspect-ratio feedback
- Recording settings for FPS, duration, countdown, audio source, encoder, output format, quality, and optional auto-hide
- Global start/stop hotkey: `Ctrl+Alt+R`
- Optional webcam window driven by `ffplay`
- FFmpeg subprocess backend for X11 screen capture
- Clean recorder shutdown so MP4 recordings are finalized correctly

## Webcam Model

The webcam is not composited into FFmpeg anymore.

When `Show webcam window` is enabled:

- the app launches a small always-on-top webcam window
- the webcam window can be mirrored with the `Mirror webcam` option
- you position that window inside the area you want to record
- the normal screen recording captures it just like any other window

This keeps recording smooth and avoids the choppy output caused by live FFmpeg webcam compositing.

## Project Structure

- `src/NimScreenRecorder.nim`: binary entrypoint
- `src/ui.nim`: window layout and UI bindings
- `src/state.nim`: recorder state, presets, and environment detection
- `src/preview.nim`: desktop preview widget and region selection logic
- `src/ffmpeg.nim`: FFmpeg argument generation for screen recording
- `src/recorder.nim`: FFmpeg recording subprocess lifecycle
- `src/restorefix.nim`: Linux/X11 window restore workaround for global-hotkey stop
- `src/windowpicker.nim`: X11 window selection and geometry lookup via `xdotool`
- `src/webcam.nim`: webcam device detection and `ffplay` window lifecycle

## Requirements

- Nim 2.2+
- NiGui
- FFmpeg
- FFplay
- xdotool
- Linux desktop session
- X11 display

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
```

Both Nimble tasks place the binary in `./bin`.

## Notes

- Preview refreshes by capturing desktop screenshots with FFmpeg.
- Default output directory is `~/Videos/<Project Name>`.
- If the project name is blank, the recording file name falls back to a timestamp.
- Output folder input is normalized so the UI shows the resolved recording path.
- Capture mode can switch between free region capture and selected-window capture.
- Encoder choices are limited to what the local FFmpeg build and device stack support.
- Recording format can be switched between `MP4` and `MKV`.
- Quality presets map to simple defaults for the selected encoder: `Fast`, `Balanced`, and `High`.
- The main window can be hidden automatically once recording starts.
- `Hide app window while recording` now minimizes the app instead of removing it completely.
- The global recording hotkey is `Ctrl+Alt+R`.
- Window capture mode requires `xdotool` so the app can pick and re-sync X11 window bounds.
- `ffplay` must be available on `PATH` for the webcam window feature.
- The webcam window opens borderless near the top-right of the current capture area by default.
- Webcam placement is controlled with the `Position` and `Margin` settings in the app.
