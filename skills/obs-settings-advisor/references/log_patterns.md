# OBS log patterns

What the lines in an OBS log mean, how `analyze_obs_log.py` reports them, and the usual fixes.
OBS writes frame statistics **only when an output stops**, so a log needs at least one stopped
stream, recording or replay buffer. Help > Log Files in OBS shows or uploads the log.

Thresholds used by the analyzer: warning at 0.5% of frames, critical at 5%. OBS shows the
"Encoding overloaded" warning from about 0.1% skipped frames.

## The three different frame problems

They have different causes. Do not mix them up when advising.

| Log line | Analyzer field | Problem id | Cause |
|---|---|---|---|
| `Video stopped, number of skipped frames due to encoding lag: X/Y (Z%)` | `encoder_skipped_pct` | `encoder_overloaded` | The encoder is too slow for resolution x FPS x preset |
| `Output '...': Number of lagged frames due to rendering lag/stalls: X (Z%)` | `rendering_lagged_pct` | `rendering_lag` | OBS could not render frames in time: GPU overloaded |
| `Output '...': Number of dropped frames due to insufficient bandwidth/connection stalls: X (Z%)` | `network_dropped_pct` | `network_dropped_frames` | Network cannot sustain the bitrate |

### Skipped frames: encoder overloaded

Fixes, in order of least quality loss:

1. Hardware encoders: turn off look-ahead and multipass, then use a faster preset (NVENC P6 to P5
   to P4; AMF Quality to Balanced).
2. x264: faster preset (veryfast to superfast), or switch to the hardware encoder.
3. Lower output resolution (e.g. 1080p to 936p) or FPS (60 to 30; >60 to 60).
4. If rendering lag is also high, the GPU is saturated: fix that first (below). A GPU-bound game
   also slows GPU encoders.
5. Two recording/streaming encoders at once double the work: use "Same as stream" for recording
   or a lighter recording preset.

### Rendering lag: GPU overloaded

1. Cap the game's FPS (in-game limiter, V-Sync, or driver limiter) a little below what it reaches
   so the GPU is not at 100%. This is the most effective fix.
2. Windows: run OBS as administrator so it gets GPU priority (log line `Running as
   administrator: false` and `D3D11 GPU priority setup failed (not admin)` confirm it was not).
3. Lower the OBS base (canvas) resolution, use Bicubic instead of Lanczos, reduce heavy browser
   sources, filters and scene complexity; disable the preview if needed.
4. Windows: Game Mode and Hardware-accelerated GPU Scheduling can help or hurt depending on the
   system; see the OBS "Windows Gaming Features Troubleshooting" guide and test one change at a time.
5. Laptops: OBS must run on the GPU that renders the game (`obs_on_integrated_gpu`). See the OBS
   GPU Selection Guide.

### Dropped frames: network

1. Lower the video bitrate to about 75% of sustained upload.
2. Ethernet instead of Wi-Fi. The log line `Interface: ... (wireless, ...)` shows Wi-Fi was used.
3. Choose a closer or different ingest server; try at another time of day.
4. Dynamic Bitrate (Settings > Advanced > Network) lowers bitrate instead of dropping frames.
   `Congestion detected, dropping bitrate to ...` lines mean it is kicking in often.
5. Security software, VPNs and router QoS can interfere: see the OBS "Stream Connection
   Troubleshooting" guide.

Lines like `Disconnected from`, `Reconnecting in`, `Socket error`, `RTMP send error` mean the
connection dropped completely (`stream_disconnects`).

## Encoder settings blocks

Each encoder logs its settings when an output starts, for example:

```
[obs-nvenc: 'advanced_video_stream'] settings:
	codec:        H264
	rate_control: CBR
	bitrate:      6000
	keyint:       120
	preset:       p5
	...
```

- The name in quotes tells the role: `*_stream` is the streaming encoder, `*_recording` or
  `Replay Buffer` is recording.
- `keyint` is in frames for most encoders: 120 at 60 fps is 2 s. `250` usually means "auto"
  (0 in the UI), which is too long for streaming (`stream_keyframe_interval`).
- x264 logs `preset:` and `profile:` on separate lines before its `settings:` block.
- Other prefixes: `[jim-nvenc: ...]` (OBS 28-30), `[texture-amf-h264: ...]`, `[qsv encoder: ...]`,
  `[VideoToolbox <output>: 'h264']`, `[FFmpeg VAAPI encoder: ...]`.

## Startup lines worth reading

| Line | Meaning |
|---|---|
| `OBS 31.0.2 (64-bit, windows)` | OBS version |
| `video settings reset:` block | Base/output resolution, downscale filter, FPS, color format |
| `Available Encoders:` block | Encoders OBS can use with this driver (authoritative) |
| `Loading up D3D11 on adapter <GPU>` / `Loading up OpenGL on adapter <GPU>` | GPU OBS renders on |
| `Adapter 0: ...`, `Driver Version: ...`, `HAGS Status: ...` | Windows GPU list and driver |
| `[obs-nvenc] NVENC version: ... AV1 supported: false` | NVENC driver API and AV1 support |
| `FFmpeg VAAPI H264 encoding not supported` | VAAPI cannot encode on the default device (normal on NVIDIA systems) |
| `LIBVA_DRIVER_NAME variable is set...` | Env var may break VAAPI |
| `Encoder ID 'obs_nvenc_h264_tex' not found` | Profile uses an encoder that failed to load: driver problem (`configured_encoder_missing`) |
| `Running as administrator: false` | Windows: no GPU priority for OBS |
| `Game Mode: On`, `Hardware GPU Scheduler: On` | Windows gaming features state |

## Hardware encoder errors

Lines mentioning NVENC/AMF/QSV/VAAPI/VideoToolbox together with `error`, `fail` or `unable`
(`hardware_encoder_error`). Common causes: outdated or broken driver, another app holding encoder
sessions, VRAM exhausted, unsupported setting for that GPU (e.g. B-frames on an old GPU), or a
Flatpak OBS without the matching NVIDIA runtime. Fix: update the driver, close other recording
apps (GeForce Experience/NVIDIA App instant replay, Discord streaming, AMD ReLive), then retry.

## Profiler section

At shutdown OBS prints `== Profiler Results ==`. `obs_graphics_thread` median time above the
frame budget (16.7 ms at 60 fps, 8.3 ms at 120 fps) confirms rendering is too slow. The analyzer
does not parse this; read it manually when rendering lag is unclear.

## Comparing before and after

When the user tests new settings, compare the same kind of session (same game, similar length):
`worst_encoder_skipped_pct`, `worst_rendering_lagged_pct`, `worst_network_dropped_pct` should all
be below 0.5%. A short test that shows 0% is encouraging but not proof; peaks happen in busy
scenes, so test with real gameplay, not a menu.
