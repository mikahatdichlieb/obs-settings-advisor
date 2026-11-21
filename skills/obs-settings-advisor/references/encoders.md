# Encoder decision guide

Snapshot written 2026-11. GPU generations and OBS encoder options change; confirm anything
that drives a recommendation with the sources in `sources.md`.

## 1. What counts as proof that an encoder exists

Use the strongest source you have, in this order:

1. **The OBS log's `Available Encoders` list** (`available_video_encoders` from
   `analyze_obs_log.py`). OBS probes the driver at startup, so this list is exactly what this OBS
   build can use on this PC. Example: `[obs-nvenc] ... AV1 supported: false` on an RTX 3070 is proof
   that AV1 is not available, whatever a blog says.
2. **The user's encoder dropdown** in Settings > Output (ask them to read it out).
3. **`detect_hardware` → `hw_encoder`**. `source: "vainfo"` is a real driver report.
   `source: "inferred_from_model"` is only a heuristic from the model name.
4. **Vendor support matrices** (see `sources.md`).

If you only have level 3 heuristics or 4, say "your GPU should support X, check that it appears in
Settings > Output > Video Encoder". Never state codec support as fact without level 1 or 2.

## 2. Encoder IDs you will see in logs

Names differ between OBS versions. These are the common ones:

| Log ID (examples) | UI name | Runs on |
|---|---|---|
| `obs_nvenc_h264_tex`, `obs_nvenc_hevc_tex`, `obs_nvenc_av1_tex` | NVIDIA NVENC H.264 / HEVC / AV1 (OBS 31+ native NVENC) | NVIDIA GPU |
| `jim_nvenc`, `jim_hevc_nvenc`, `jim_av1_nvenc` | NVIDIA NVENC (OBS 28-30) | NVIDIA GPU |
| `ffmpeg_nvenc` | NVENC via FFmpeg (fallback, slower path) | NVIDIA GPU |
| `h264_texture_amf`, `h265_texture_amf`, `av1_texture_amf` | AMD HW H.264 / HEVC / AV1 | AMD GPU |
| `obs_qsv11_v2`, `obs_qsv11_hevc`, `obs_qsv11_av1` | QuickSync H.264 / HEVC / AV1 | Intel iGPU or Arc |
| `com.apple.videotoolbox.videoencoder.ave.avc` / `.hevc` | Apple VT H264 / HEVC Hardware Encoder | Apple media engine |
| `ffmpeg_vaapi_tex`, `ffmpeg_hevc_vaapi_tex`, `ffmpeg_av1_vaapi_tex` | FFmpeg VAAPI H.264 / HEVC / AV1 | AMD/Intel on Linux |
| `obs_x264` | x264 | CPU |
| `ffmpeg_svt_av1`, `ffmpeg_aom_av1` | SVT-AV1, AOM AV1 | CPU (very heavy; not for gaming PCs) |

The `*_tex` (texture) variants take frames straight from the GPU and are the efficient path. A
non-texture variant on a capable system usually points to a driver or OBS build problem.

## 3. Decision order

For a PC that also runs the game:

1. **Use the hardware encoder of the GPU that renders the game.** It is a dedicated chip, so it
   costs almost no CPU. It still needs some GPU headroom: OBS composites the scene on the GPU, and a
   GPU at 100% causes rendering lag (see `log_patterns.md`).
2. **x264 only if** there is no usable hardware encoder, or the PC has plenty of spare CPU (dedicated
   streaming PC, light game on a 12+ core CPU) and the bitrate is low enough that x264's better
   quality per bit matters. Always confirm with skipped frames in a test.
3. **Codec:** for streaming, use what the platform accepts (see `platforms.md`). H.264 works
   everywhere. For recording, prefer HEVC or AV1 when the GPU has them and the user's editor decodes
   them; use H.264 for maximum editing compatibility.
4. **Older H.264 hardware encoders** (NVIDIA Pascal and older, AMD before RDNA4, Intel before Arc)
   look noticeably worse than Turing+ NVENC at 6 Mbps 1080p60. Lower the resolution (936p/900p/720p)
   or use HEVC/AV1 where the platform allows, rather than promising 1080p60 quality.

### Load intuition: pixels per second

Encoder and compositing cost scale with width x height x FPS.

| Output | Megapixels/s | vs 1080p60 |
|---|---|---|
| 1280x720 @ 60 | 55 | 0.44x |
| 1920x1080 @ 30 | 62 | 0.5x |
| 1920x1080 @ 60 | 124 | 1x |
| 2560x1440 @ 60 | 221 | 1.8x |
| 3840x2160 @ 60 | 498 | 4x |
| 2560x1440 @ 240 | 885 | 7.1x |

A slow preset (NVENC P7 + look-ahead + multipass) that is fine at 1080p60 can overload at
1440p120+. If the user records at high FPS, drop the preset first.

## 4. NVIDIA NVENC

| Generation | GeForce cards | H.264 | HEVC | AV1 | Notes |
|---|---|---|---|---|---|
| Maxwell 2 (GM20x) | GTX 950-980 | yes | yes | no | Old; low quality per bit. Check the current OBS minimum driver/GPU. |
| Pascal (GP10x) | GTX 1050-1080 Ti | yes | yes | no | No HEVC B-frames. **GT 1030 has no NVENC.** |
| Turing (TU10x, TU116) | RTX 20xx, GTX 1660, 1650 Super | yes | yes | no | Big quality jump; good 1080p60 at 6 Mbps. Early GTX 1650 (TU117) uses the older Volta-class NVENC. |
| Ampere (GA10x) | RTX 30xx | yes | yes | no | Same encoder quality as Turing; AV1 is decode-only. |
| Ada (AD10x) | RTX 40xx | yes | yes | **yes** | Higher-end cards have 2 NVENC units. |
| Blackwell (GB20x) | RTX 50xx | yes | yes | **yes** | Adds 4:2:2 H.264/HEVC encode, improved AV1 quality modes. |

Laptop MX and most GT models have no NVENC. Consumer GeForce cards limit concurrent NVENC
sessions; check the support matrix for the current limit.

OBS NVENC settings (labels from OBS 30+):

- **Rate control:** CBR for streaming. CQP (or VBR with a high max) for recording; start at CQ 18-23
  for H.264 and check file size and quality.
- **Preset:** P1 (fastest) to P7 (slowest). Streaming start: P5 or P6. If skipped frames appear,
  go to P4 before cutting resolution.
- **Tuning:** High Quality. Ultra Low Latency only if the user truly needs it (Kick's guide asks
  for it); it costs quality.
- **Multipass:** Two Passes (Quarter Resolution) is a good streaming default. Full Resolution costs
  more; disable multipass when overloaded.
- **Profile:** high (H.264), main (HEVC/AV1), main10 only for HDR.
- **Look-ahead:** off by default. Can help high-motion content at low bitrate, costs encoder time.
  First thing to turn off when frames are skipped.
- **Psycho Visual Tuning:** on (adaptive quantization). Turn off only for troubleshooting.
- **B-frames:** 2 (OBS default) for streaming.

## 5. AMD AMF (Windows) / VAAPI (Linux)

| Generation | Cards | H.264 | HEVC | AV1 | Notes |
|---|---|---|---|---|---|
| Polaris | RX 460-590 | yes | yes | no | Weak H.264 at low bitrate. |
| Vega | Vega 56/64, Radeon VII, Vega iGPUs | yes | yes | no | |
| RDNA1 | RX 5500-5700 | yes | yes | no | |
| RDNA2 | RX 6600-6950, Radeon 680M | yes | yes | no | **RX 6400 and 6500 XT have no encoder.** |
| RDNA3 / 3.5 | RX 7600-7900, Radeon 780M/880M/890M | yes | yes | **yes** | |
| RDNA4 | RX 9060/9070 | yes | yes | **yes** | Much improved H.264 quality vs older AMD. |

AMD H.264 at 6 Mbps has historically trailed NVENC. When the platform accepts HEVC/AV1 (YouTube,
Twitch Enhanced Broadcasting HEVC), recommend it for AMD. Settings: CBR, Preset Quality (Balanced
if overloaded), Profile high, keyframe 2 s.

## 6. Intel QuickSync (QSV)

| Generation | Examples | H.264 | HEVC | AV1 |
|---|---|---|---|---|
| Gen9 (Skylake) | HD 530 | yes | partial | no |
| Gen9.5 / Gen11 | UHD 620/630, Iris Plus | yes | yes | no |
| Gen12 Xe-LP | Iris Xe, UHD 710-770 (11th-14th gen desktop) | yes | yes | no (decode only) |
| Xe-HPG / Xe-LPG | Arc A-series, Core Ultra "Arc Graphics" iGPU | yes | yes | **yes** |
| Xe2 | Arc B-series, Core Ultra 200V | yes | yes | **yes** |

**CPUs ending in F/KF (e.g. i5-12400F) have no iGPU, so no QuickSync.** Check the CPU model.
Using the iGPU's QSV while the game runs on an NVIDIA/AMD card works mainly for recording; keep it
simple and use the gaming GPU's encoder unless it is missing or overloaded.

## 7. Apple VideoToolbox (macOS)

- Apple silicon (M1 and later): hardware H.264 and HEVC. ProRes encode on M1 Pro/Max/Ultra and
  M2 and later. No AV1 hardware encode as of this snapshot (M3/M4 decode AV1 only); verify for
  newer chips.
- Intel Macs: H.264 via VideoToolbox; HEVC on 7th-gen Intel and later or with a T2 chip.
- CBR in OBS's Apple VT encoder depends on macOS version and chip; if CBR is not offered, use
  ABR/VBR with a bitrate cap and say so.

## 8. Linux specifics

- **NVIDIA:** needs the proprietary driver (nouveau has no NVENC). OBS Flatpak needs the
  `org.freedesktop.Platform.GL.nvidia-*` runtime matching the installed driver, or NVENC is missing.
- **AMD/Intel:** check `vainfo` for `VAEntrypointEncSlice` lines. Some distributions (notably
  Fedora) ship Mesa without H.264/HEVC encoding for patent reasons; the fix is the distribution's
  "freeworld" Mesa VA drivers (for example RPM Fusion's `mesa-va-drivers-freeworld`).
- **Intel:** `intel-media-driver` (iHD) for Broadwell and newer. OBS 30+ also offers QSV on Linux.
- `LIBVA_DRIVER_NAME` set to the wrong driver (OBS logs a warning) breaks VAAPI.
- Wayland capture goes through PipeWire; capture cost is low, but check for rendering lag.

## 9. x264 (CPU)

- Presets from ultrafast to veryslow; each slower step costs a lot more CPU for small gains.
- On the gaming PC: veryfast (OBS default), faster only with clear CPU headroom. Never medium or
  slower at 1080p60 while gaming unless a test shows zero skipped frames.
- CBR, keyframe 2 s, profile high. Tune: none (Kick's guide suggests zerolatency, which lowers
  quality; mention it as Kick's recommendation, not a requirement).

## 10. HEVC and AV1 for streaming

Streaming HEVC/AV1 from OBS uses Enhanced RTMP or other modern protocols. Support depends on the
platform (see `platforms.md`), the OBS version and the GPU. Viewers on old devices may get
transcodes or fallbacks depending on the platform. Always verify the platform's current rules with
a search before recommending HEVC/AV1 for a stream.
