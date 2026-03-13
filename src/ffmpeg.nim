import times

import state

# FFmpeg argument construction lives here so recording stays decoupled from the UI.

proc x264QualitySettings(state: RecorderState): tuple[preset, crf: string] =
  # Friendly quality labels map to stable x264 defaults.
  case state.quality
  of QualityFast:
    ("ultrafast", "28")
  of QualityHigh:
    ("medium", "18")
  else:
    ("veryfast", "23")

proc nvencQualitySettings(state: RecorderState): tuple[preset, cq: string] =
  case state.quality
  of QualityFast:
    ("p1", "28")
  of QualityHigh:
    ("p6", "18")
  else:
    ("p4", "23")

proc vaapiQualitySettings(state: RecorderState): string =
  case state.quality
  of QualityFast:
    "28"
  of QualityHigh:
    "18"
  else:
    "23"

proc x11InputTarget*(state: RecorderState, x, y: int): string =
  let display = if state.display.len == 0: ":0.0" else: state.display
  display & "+" & $x & "," & $y

proc buildOutputFilePath*(state: RecorderState): string =
  # Use timestamps to avoid accidental overwrites across repeated test recordings.
  let timestamp = now().format("yyyy-MM-dd'_'HH-mm-ss")
  state.buildPlannedOutputPath(timestamp)

proc buildRecordingArgsForFormat(state: RecorderState, outputPath, outputFormat: string, duration: int): seq[string] =
  # Recording intentionally stays simple: screen capture plus optional microphone input.
  let audioEnabled = state.audioSource != NoAudioSource

  result = @[
    "-y",
    "-hide_banner",
    "-loglevel", "error",
    "-nostats",
    "-f", "x11grab",
    "-framerate", $state.fps
  ]

  if state.captureMode == CaptureModeWindow and state.targetWindowId.len > 0:
    result.add(@[
      "-window_id", state.targetWindowId,
      "-i", (if state.display.len == 0: ":0.0" else: state.display)
    ])
  else:
    result.add(@[
      "-video_size", $state.width & "x" & $state.height,
      "-i", state.x11InputTarget(state.posX, state.posY)
    ])

  if audioEnabled:
    result.add(@[
      "-f", "pulse",
      "-thread_queue_size", "512",
      "-i", state.audioSource
    ])

  if audioEnabled:
    result.add(@["-map", "0:v:0", "-map", "1:a:0"])

  if duration > 0:
    result.add(@["-t", $duration])

  case state.encoder
  of EncoderVaapi:
    let qp = state.vaapiQualitySettings()
    result.add(@[
      "-vaapi_device", "/dev/dri/renderD128",
      "-vf", "format=nv12,hwupload",
      "-c:v", "h264_vaapi",
      "-qp", qp,
      "-profile:v", "high",
      "-c:a", "aac",
      "-b:a", "160k",
      "-r", $state.fps
    ])
  of EncoderNvenc:
    let quality = state.nvencQualitySettings()
    result.add(@[
      "-c:v", "h264_nvenc",
      "-preset", quality.preset,
      "-rc", "vbr",
      "-cq", quality.cq,
      "-pix_fmt", "yuv420p",
      "-c:a", "aac",
      "-b:a", "160k",
      "-r", $state.fps
    ])
  else:
    let quality = state.x264QualitySettings()
    result.add(@[
      "-c:v", "libx264",
      "-preset", quality.preset,
      "-crf", quality.crf,
      "-pix_fmt", "yuv420p",
      "-c:a", "aac",
      "-b:a", "160k",
      "-r", $state.fps
    ])

  if outputFormat == OutputFormatMp4:
    result.add(@["-movflags", "+faststart"])

  result.add(outputPath)

proc buildSegmentRecordingArgs*(state: RecorderState, outputPath: string): seq[string] =
  # Segments are always recorded as MKV so paused sessions can be concatenated safely.
  state.buildRecordingArgsForFormat(outputPath, OutputFormatMkv, 0)

proc buildConcatArgs*(listPath, outputPath, outputFormat: string): seq[string] =
  # Final output is assembled from one or more MKV segments with stream copy.
  result = @[
    "-y",
    "-hide_banner",
    "-loglevel", "error",
    "-nostats",
    "-f", "concat",
    "-safe", "0",
    "-i", listPath,
    "-c", "copy"
  ]

  if outputFormat == OutputFormatMp4:
    result.add(@["-movflags", "+faststart"])

  result.add(outputPath)

proc buildSnapshotArgs*(state: RecorderState, outputPath: string): seq[string] =
  # Preview captures a single desktop frame at a time to keep the UI simple.
  @[
    "-y",
    "-hide_banner",
    "-loglevel", "error",
    "-nostats",
    "-nostdin",
    "-f", "x11grab",
    "-video_size", $state.desktopWidth & "x" & $state.desktopHeight,
    "-i", state.x11InputTarget(0, 0),
    "-frames:v", "1",
    outputPath
  ]
