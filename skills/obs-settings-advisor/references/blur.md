# blur configs that fit the OBS recording

[blur](https://github.com/f0e/blur) adds motion blur to recordings by blending (and optionally
interpolating) frames, typically from high-FPS gameplay recordings down to a 60 fps video.
Format snapshot: blur v2.45 (source checked 2026-11-21). Before writing a config, check the user's
installed version (the header line `[blur vX.YZ]` of an existing config, or the latest release at
https://github.com/f0e/blur/releases) and the README's "Config settings explained" section.

## 1. Make the OBS recording fit blur first

blur can only blend frames that exist, so the OBS side decides the quality. Use the high-FPS
recording profile in `encoders.md` section 11 (FPS via Fractional FPS Value, quality-based rate
control, fast preset, NV12) and confirm it with `analyze_obs_log.py --goal blend` before writing
a config. blur reads MKV and Hybrid MP4 through FFmpeg.

The game must render at least the recording FPS. If it runs at 144 fps and OBS records at 240, a
third of the recorded frames are duplicates (`deduplicate` covers this partly, see below).

## 2. Where the config goes

- Per folder: `.blur-config.cfg` in the folder with the videos (for example the OBS recording
  folder). It takes priority over the global one.
- Global: `%APPDATA%\blur\.blur-config.cfg` (Windows),
  `~/Library/Application Support/blur/.blur-config.cfg` (macOS),
  `${XDG_CONFIG_HOME:-~/.config}/blur/.blur-config.cfg` (Linux).

Give the config as a code block. Write it to disk only if the user asks, and never overwrite an
existing `.blur-config.cfg` without showing what changes and getting a yes. blur fills missing keys
with defaults and rewrites the file in its own layout when it loads it, so a short config with only
the relevant keys is valid, and configs from older v2 versions load fine.

## 3. Format

- First line `[blur v<version>]`, then `key: value` lines. Lines without a colon (section titles
  like `- blur`) are ignored.
- Booleans are `true`/`false`. Spaces inside values are removed when parsed (except
  `custom ffmpeg filters`).
- Unknown keys are ignored silently. That is how old v1 configs break without an error (section 6).
- Keys under the advanced sections (`deduplicate range`, `deduplicate threshold`, `video container`,
  `custom ffmpeg filters`, `svp interpolation preset`, `svp interpolation algorithm`,
  `interpolation block size`, `interpolation mask area`, `rife model`, gaussian weighting
  parameters, manual SVP strings) are only read when `advanced: true` is set.
- `custom ffmpeg filters` replaces blur's own encoder, GPU encoding and `quality` settings.
- `interpolated fps` and `pre-interpolated fps` accept multipliers like `5x`; `blur output fps` is a
  plain number.

Main keys (defaults in v2.45 on Windows/Linux; macOS uses RIFE and 600 fps interpolation):

| Key | Default | Meaning |
|---|---|---|
| `blur` | true | Motion blur on/off |
| `blur amount` | 1 | 0 = none, 1 = blend all frames of an output frame, >1 = more blur/ghosting |
| `blur output fps` | 60 | FPS of the output video |
| `blur weighting` | equal | equal, gaussian_sym, vegas, pyramid, gaussian, ascending, descending, gaussian_reverse, or custom weights like `5,3,3,2,1` |
| `blur gamma` | 1 | Gamma used while blending; above 1 makes bright trails stand out more |
| `interpolate` | true | Interpolate before blurring |
| `interpolated fps` | 1200 | Interpolation target. Lower = sharper blur, higher = smoother blur |
| `interpolation method` | svp | svp (fast) or rife (better quality, slower; default on macOS, where SVP needs a paid SVP Manager) |
| `pre-interpolate` / `pre-interpolated fps` | false / 360 | RIFE step before SVP. Inputs below this FPS get RIFE first, which reduces SVP artifacts on low-FPS footage; much slower |
| `deduplicate` / `deduplicate method` | true / svp | Replace duplicate frames (stutter) with interpolated ones; rife is better, slower |
| `encode preset` | h264 | h264, h265, av1 (plus vp9 on CPU, prores with VideoToolbox) |
| `quality` | 16 | CRF/CQ of the output: lower = better and bigger |
| `preview` / `detailed filenames` / `copy dates` | true / false / false | Preview window (costs speed), settings in file names, keep file dates |
| `gpu decoding` / `gpu interpolation` / `gpu encoding` | true / true / false | GPU encoding uses NVENC/AMF/QSV/VideoToolbox for the output |
| `timescale`, `input timescale`, `output timescale`, `adjust timescaled audio pitch` | false, 1, 1, false | Speed up / slow down |
| `filters`, `brightness`, `saturation`, `contrast` | false, 1, 1, 1 | Color filters (only applied with `filters: true`) |
| `advanced` | false | Enables the advanced keys listed above |

## 4. Matching config to the recording

- **Interpolated fps:** blur's README recommends about 5x the input FPS; SVP cannot go beyond 10x.
  Popular configs use 960-2400 (4-10x of 240 fps recordings). `5x` follows the OBS FPS automatically.
  With 240+ fps recordings `interpolate: false` renders much faster, with less smooth blur.
- **Pre-interpolation** helps inputs below ~240 fps that show SVP warping; set its FPS a bit above
  the recording FPS (for example 360-480 for 240 fps). Expect several times longer renders.
- **Blur amount** (60 fps output): >1 heavy, 1 normal, 0.5 medium, 0.2-0.3 low. To keep the look at
  another output FPS: `new amount = old amount x (new fps / old fps)`.
- **Output FPS:** the upload target, usually 60. 120 fps output doubles file size and only helps
  where the platform plays it back at 120.
- **Game FPS below recording FPS:** keep `deduplicate: true`; set `advanced: true` and raise
  `deduplicate range` (default 2) if the result still looks choppy, lower it if menus get blurred.
- **GPU encoding:** `gpu encoding: true` only if detect_hardware / the OBS log shows a hardware
  encoder. `encode preset: av1` needs AV1 encode (RTX 40+, RX 7000+, Intel Arc); else h264 or h265.

## 5. Popular community configs (patterns, not rules)

Collected from configs players share; use them as starting points and explain the tradeoff.

| Style | Typical values |
|---|---|
| Works for any input FPS | amount 1, equal, interpolated 1200 svp, pre-interpolate 360, deduplicate svp, h264 quality 16, gpu encoding on. Slow because of the RIFE pre-interpolation; turn that off if renders take too long |
| Minecraft PvP / Bedwars (240-540 fps recordings) | amount 1.4-1.6, gaussian_sym, interpolated 1440-2400 svp, optional pre-interpolate 480-970, h265 quality 15-17, mild filters (saturation 1.1, contrast 1.05), sometimes svp preset `smooth` |
| Shooter clips at 120 fps output (240 fps recording) | amount ~1.7, output 120, vegas weighting, gamma ~1.35, interpolated 1440, h264 quality 14, saturation boost ~1.25 |
| Crisp, less blur | amount 0.8, equal, interpolated `10x` with rife, deduplicate rife, quality 15 |
| Upload tricks | advanced `custom ffmpeg filters` to upscale to 4K for a higher-bitrate YouTube encode, or SVT-AV1 10-bit output for small files. Replaces blur's quality/GPU encode settings, renders slower |

Patterns: amounts 0.8-1.7; gaussian_sym is common for Minecraft, equal elsewhere; filters stay
close to 1 (0.05-0.25 changes).

## 6. Reviewing a user's existing config

Check these before suggesting values:

1. **Old blur v1 format** (keys such as `interpolation program (svp/rife/rife-ncnn)`,
   `interpolation speed`, `interpolation tuning`, `interpolation algorithm`, `gpu`,
   `gpu type (nvidia/amd/intel)`, `blur weighting bound`, `blur weighting triangle reverse`). v2
   ignores these silently and uses defaults. Convert:

   | v1 key | v2 key |
   |---|---|
   | `interpolation program (svp/rife/rife-ncnn)` | `interpolation method` (svp or rife) |
   | `interpolation tuning` | `svp interpolation preset` (advanced) |
   | `interpolation algorithm` | `svp interpolation algorithm` (advanced) |
   | `blur weighting bound` | `blur weighting gaussian bound` (advanced) |
   | `gpu` | `gpu decoding` / `gpu interpolation` / `gpu encoding` |
   | `gpu type (nvidia/amd/intel)`, `interpolation speed`, `blur weighting triangle reverse` | none (the GPU type is an app setting in `blur.cfg`, not part of the config) |

2. **Advanced keys without `advanced: true`** are ignored, including `custom ffmpeg filters`.
3. **Broken values**, for example a key name pasted twice
   (`custom ffmpeg filters: custom ffmpeg filters: -vf ...`): the extra text is passed to FFmpeg.
4. **`custom ffmpeg filters` set** means `encode preset`, `quality` and `gpu encoding` do nothing.
5. **Quality below ~10** gives huge files with little visible gain after platform re-encoding.
6. **"Too unclear / smeary"**: lower `blur amount` (for example 1.3 to 0.9-1.0), lower
   `interpolated fps`, use `equal` instead of `gaussian_sym`, record at higher FPS instead of
   interpolating more. Keep color filters within about ±0.1 of 1, and use sharpening (for example
   FFmpeg `cas`) sparingly.

## 7. Example: OBS 1440p at 240 fps, NVIDIA GPU, 60 fps upload

```
[blur v2.45]

- blur
blur: true
blur amount: 1
blur output fps: 60
blur weighting: equal

- interpolation
interpolate: true
interpolated fps: 5x
interpolation method: svp

- deduplication
deduplicate: true

- rendering
encode preset: h264
quality: 16
preview: false

- gpu acceleration
gpu decoding: true
gpu interpolation: true
gpu encoding: true
```

Pair it with the OBS recording profile from `encoders.md` section 11 (240/1 fractional FPS, CQ ~16,
NVENC P1-P4, MKV), and check the next recording's log with `--goal blend` before blurring a whole
session. For the same look in Smoothie, see the key mapping in `smoothie.md`.
