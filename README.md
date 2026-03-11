# Nim Screen Recorder

Linux desktop screen recorder prototype written in Nim with NiGui and FFmpeg.

## Features

- Desktop preview panel with a draggable and resizable capture rectangle
- Project settings for project name and output folder
- Capture settings for preset, width, height, X, and Y
- Recording settings for FPS, duration, and audio source
- FFmpeg subprocess backend for X11 screen capture
- Clean stop handling so MP4 recordings are finalized correctly

## Project Structure

- `src/NimScreenRecorder.nim`: binary entrypoint
- `src/main.nim`: app startup
- `src/ui.nim`: window layout and UI bindings
- `src/state.nim`: recorder state and desktop/audio defaults
- `src/preview.nim`: desktop preview widget and region selection logic
- `src/ffmpeg_builder.nim`: FFmpeg command generation
- `src/recorder.nim`: recording subprocess lifecycle

## Requirements

- Nim 2.2+
- NiGui
- FFmpeg
- Linux desktop session
- X11 display

## Build

Debug build and run:

```bash
nim c -r src/NimScreenRecorder.nim
```

Release build and run:

```bash
nim c -d:release -r src/NimScreenRecorder.nim
```

## Notes

- Preview refreshes by capturing desktop screenshots with FFmpeg.
- Default output directory is `~/Videos/<Project Name>`.
- If the project name is blank, the recording file name falls back to a timestamp.
