# Smoothie recipes that fit the OBS recording

[Smoothie](https://github.com/couleur-tweak-tips/smoothie-rs) (smoothie-rs) does the same job as
blur: it blends high-FPS recordings, optionally interpolated with SVP or RIFE, into a lower-FPS
video with motion blur. Its config is a `recipe.ini`. Format snapshot: smoothie-rs
Nightly_2026.04.10 (source checked 2026-11-21: `target/defaults.ini`, `target/recipe.ini`,
`target/encoding_presets.ini`, `target/jamba.vpy`). The ctt.cx recipe docs are older than this
code in places (defaults, `custom` weighting); when they disagree, trust the code. Ask which
version the user runs, and check the repository if it is newer.

## 1. Make the OBS recording fit first

Same as for blur: use the high-FPS profile in `encoders.md` section 11 and confirm it with
`analyze_obs_log.py --goal blend`. Smoothie-specific points:

- Record at least 120 fps. Smoothie's docs say SVP interpolation of 60 fps input often looks
  worse than the raw clip.
- Color Format NV12. With I444, SVP interpolation switches to a slower workaround, and RIFE
  pre-interpolation can crash with some OBS color settings (sRGB + Limited is reported to work).
- If `[frame blending] fps` is higher than the recording FPS (for example a 30 fps clip with
  `fps: 60`), Smoothie skips blending without an error.

## 2. Where the recipe goes

- Windows: `recipe.ini` in the Smoothie install folder (the folder that holds `defaults.ini`,
  `encoding_presets.ini` and the `bin` folder).
- Linux: `~/.config/smoothie-rs/recipe.ini` (portable installs keep it next to the program).
- More recipes: put `name.ini` in the same folder and start Smoothie with `--recipe name.ini`
  (before `-i` in Send To shortcuts).

Give the recipe as a code block. Write it to disk only if the user asks. Prefer a new file
(`blend.ini` used with `--recipe blend.ini`) over editing `recipe.ini`, and never overwrite an
existing recipe without showing the changes and getting a yes.

## 3. Format

Smoothie is strict, unlike blur: mistakes stop it with an error instead of being ignored.

- Allowed lines: `[section]`, `key: value`, empty lines, and comments starting with `#`, `;`, `/`
  or `:`. Any other line stops Smoothie ("Failed to parse"), including blur-style section titles
  like `- blur`. A `key: value` line before the first section stops it too.
- `defaults.ini` loads first and the recipe overrides it, so a short recipe with only the changed
  keys is valid. `defaults.ini` has `[frame blending] enabled: no`, so a separate short recipe must
  set it to `yes` itself.
- Every key and section must exist in `defaults.ini`. A typo, a key from blur or from another
  Smoothie version stops it with "Failed to get 'type' metadata ... in defaults.ini".
- Booleans must be exactly one of `yes`/`no`, `y`/`n`, `on`/`off`, `true`/`false`, `1`/`0`
  (case-sensitive; an empty value counts as no). `Yes` or `enable` stops it with "Invalid boolean
  value". Write them in lowercase.
- `[interpolation] fps` accepts a multiplier like `5x` (of the input FPS). `[pre-interp] factor`
  is always a multiplier (`3x`).

Main keys (defaults from `defaults.ini`; the shipped `recipe.ini` only turns on frame blending):

| Section / key | Default | Meaning |
|---|---|---|
| `[frame blending] enabled` | yes (recipe.ini) | Motion blur on/off |
| `[frame blending] fps` | 60 | Output FPS |
| `[frame blending] intensity` | 1.0 | Same as blur's `blur amount` |
| `[frame blending] weighting` | equal | equal, ascending, descending, pyramid, gaussian, gaussian_sym, vegas, or a list like `[1,1,2,3,5]`. Options with `;`, e.g. `gaussian_sym; std_dev=1; bound=[0,2]`. An unknown name stops the render with an error |
| `[frame blending] bright blend` | no | Blends in RGB48 for a brighter, Premiere-like look; slower |
| `[interpolation] enabled` | no | SVP interpolation before blending |
| `[interpolation] fps` | 1920 | Target FPS, or `5x` |
| `[interpolation] speed` | medium | medium (most accurate), fast, faster, fastest |
| `[interpolation] tuning` | weak | weak (common for gameplay), smooth, film (low-FPS input), animation |
| `[interpolation] algorithm` | 23 | 23 smoothest, 13 masks more artifacts, 2 for cartoons |
| `[interpolation] block size`, `area` | auto, empty | Bigger blocks are faster and worse; keep `area` empty or 0 |
| `[interpolation] use gpu` | no | Turn on when the GPU has headroom |
| `[pre-interp] enabled`, `factor`, `model` | no, 3x, rife-v4.4 | RIFE before SVP; much slower. `model` is a model **folder**; models are not shipped |
| `[flowblur] enabled`, `amount`, `do blending` | no, 125, after | RSMB-like blur, more artifacts; use with artifact masking |
| `[output] enc args` | H264 CPU | Encoder preset, see section 4 |
| `[output] container` | .MP4 | .MP4, .MKV, .AVI, .WEBM |
| `[preview window] enabled` | no | Live preview with ffplay |
| `[artifact masking] enabled`, `folder path`, `file name` | no, empty, empty | Black/white image that keeps HUD areas unblurred |
| `[miscellaneous] source plugin` | bestsource | bestsource, ffms2, lsmash. lsmash indexes faster |
| `[miscellaneous] dedup threshold` | 0.0 | 0.0 = off. Replaces duplicate frames with interpolated ones |
| `[timescale] in` / `out`, `[color grading]`, `[lut]` | 1.0 / off | Speed and color; leave unless asked |

## 4. Encoder (`[output] enc args`)

`enc args` is `<codec> <encoder>` plus optional macros, expanded from `encoding_presets.ini`:

- Codecs: `H264`/`AVC`, `H265`/`HEVC`, and `MISC` with `SVTAV1` or `UTVIDEO`.
- Encoders: `NVENC`, `AMF`, `QUICKSYNC`, `CPU`. Example: `H265 NVENC`.
- Macros: `4K` (upscale to 3840 wide, for a higher YouTube bitrate), `COPY` (copy audio), `OPUS`,
  `YUV444`. Example: `H264 NVENC 4K`.
- Raw FFmpeg arguments also work, for example `-c:v hevc_nvenc -preset p7 -qp 18`.

Quality is fixed inside each preset (for example `H265 NVENC` is `-preset p7 -qp 19`). For a
different quality, write raw arguments or edit `encoding_presets.ini` (same folder as the recipe). There is no hardware AV1
preset by default; `MISC SVTAV1` runs on the CPU. `UTVIDEO` is lossless for fast editing and needs
`.MKV` or `.AVI`. Only pick NVENC/AMF/QUICKSYNC when detect_hardware or the OBS log shows that
encoder.

## 5. From a blur config to a recipe

ctt.cx offers a converter for `.blur-config.cfg` files. By hand:

| blur key | Smoothie |
|---|---|
| `blur: true` | `[frame blending] enabled: yes` |
| `blur amount` | `[frame blending] intensity` |
| `blur output fps` | `[frame blending] fps` |
| `blur weighting` | `[frame blending] weighting` (`gaussian_reverse` does not exist; use `descending` or a list) |
| `blur gamma` | none (`bright blend: yes` is a different, brighter look) |
| `interpolate`, `interpolated fps` | `[interpolation] enabled`, `fps` (`5x` works in both) |
| `interpolation method: rife` | none for the main step; RIFE only via `[pre-interp]` |
| `pre-interpolate`, `pre-interpolated fps: 360` | `[pre-interp] enabled`, `factor` as a multiplier (240 fps recording: `2x`) |
| `svp interpolation preset`, `svp interpolation algorithm` | `[interpolation] tuning`, `algorithm` |
| `interpolation block size`, `interpolation mask area` | `[interpolation] block size`, `area` |
| `deduplicate` | `[miscellaneous] dedup threshold` (threshold based, not the same method) |
| `gpu interpolation` | `[interpolation] use gpu` |
| `encode preset`, `quality`, `gpu encoding` | `[output] enc args` |
| `preview` | `[preview window] enabled` |
| `filters`, `brightness`, `saturation`, `contrast` | `[color grading]` |
| `timescale`, `input timescale`, `output timescale` | `[timescale] in`, `out` |

## 6. Reviewing a user's recipe

1. Lines without a colon (`- blur`), keys outside a section, misspelled keys or sections
   (`[frame-blending]`), keys copied from a blur config: each one stops Smoothie. Map blur keys
   with section 5.
2. Boolean values outside the allowed list (`Yes`, `enable`): stops Smoothie.
3. `weighting: custom ...` from older docs: the current code has no `custom` function and stops.
4. `model` pointing to a file instead of the model folder, or `auto` (removed).
5. Masks with a different resolution than the video: Smoothie crashes.
6. `container: .MP4` together with `enc args: MISC UTVIDEO`: needs .MKV or .AVI.
7. Blending FPS above the recording FPS: no blur at all. Check the OBS FPS in the log.

## 7. Example: OBS 1440p at 240 fps, NVIDIA GPU, 60 fps upload

```ini
[frame blending]
enabled: yes
fps: 60
intensity: 1.0
weighting: equal

[interpolation]
enabled: yes
fps: 5x
use gpu: yes

[output]
enc args: H264 NVENC
container: .MP4
```

This matches the blur example in `blur.md` section 7. Pair it with the OBS profile from
`encoders.md` section 11, and check the next recording's log with `--goal blend` first.
