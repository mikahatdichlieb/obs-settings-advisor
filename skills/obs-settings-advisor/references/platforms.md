# Platform constraints

Snapshot checked 2026-11-21. Platforms change limits without notice: **search for the current
official page before quoting a number to the user.** Each section says how the numbers below were
checked.

## Upload speed rule (all platforms)

- Total bitrate (video + audio) should be at most **about 75% of the sustained upload** to the
  ingest server, not the peak of a speed test. 10 Mbps upload: about 7 Mbps total.
- Wi-Fi often fails at bitrates that Ethernet handles. Prefer Ethernet.
- If the user's goal does not fit their upload, say so and lower the resolution or FPS. Rough
  guide for **H.264** with high-motion games:

| Video bitrate | Realistic output |
|---|---|
| 2.5-3.5 Mbps | 720p30, or 720p60 for slow games |
| 3.5-4.5 Mbps | 720p60 |
| 4.5-6 Mbps | 936p60/900p60 (fast shooters) or 1080p60 (slower games) |
| 6-8 Mbps | 1080p60 |
| 1440p60 | needs ~12+ Mbps H.264, or HEVC/AV1 where the platform allows |

HEVC/AV1 usually need roughly 30-40% less bitrate for similar quality. This is a rule of thumb,
not a guarantee: content and encoder generation matter.

## YouTube

Checked 2026-11-21 against the official page (support.google.com/youtube/answer/2853702).

- Protocols: RTMP/RTMPS (RTMPS recommended); HLS for HDR when the encoder cannot do HDR over RTMP.
- Codecs: H.264, H.265 (HEVC), AV1. HDR requires HEVC; AV1 is not supported for HDR.
- Frame rate up to 60 fps. Keyframe interval: 2 s recommended, never above 4 s. Rate control: CBR.
- Audio: AAC or MP3; 128 kbps stereo (384 kbps for 5.1). The page lists 44.1 kHz for stereo and
  48 kHz for 5.1. OBS defaults to 48 kHz; only change it if YouTube's stream health flags audio.
- Advanced: progressive, 2 B-frames, 1 reference frame, CABAC, Rec.709 8-bit for SDR.
- AV1 at 3840x2160 and above needs at least 2 tile columns.
- 4K streams cannot use low latency mode.
- No maximum bitrate is stated.

Bitrate ranges (Mbps) from the page:

| Resolution | AV1/HEVC min | AV1/HEVC recommended | H.264 min | H.264 recommended |
|---|---|---|---|---|
| 2160p60 | 10 | 35 | 14 | 50 |
| 2160p30 | 8 | 30 | 11 | 42 |
| 1440p60 | 6 | 24 | 8 | 34 |
| 1440p30 | 5 | 15 | 7 | 21 |
| 1080p60 | 4 | 12 | 6 | 17 |
| 1080p30 | 4 | 10 | 5 | 14 |
| 720p60 | 2 | 6 | 3 | 8 |
| 720p30 | 2 | 6 | 3 | 8 |
| 480p30 | 0.3 | 3 | 0.4 | 4 |

YouTube transcodes every stream, so it handles higher resolutions well. With limited upload, use
the "min" column as the floor and say what the user gives up.

## Twitch

**Not verified on 2026-11-21.** help.twitch.tv only renders with JavaScript and could not be
fetched. The values below are the long-standing Broadcasting Guidelines as widely reported. Search
for "Twitch broadcasting guidelines" and "Twitch Enhanced Broadcasting" before quoting them.

- Standard ingest: H.264, CBR, keyframe interval 2 s.
- Commonly cited video bitrates: 1080p60 about 6000 kbps, 720p60 about 4500 kbps, 1080p30
  about 4500 kbps, 720p30 about 3000 kbps. Treat 6000 kbps as the usual ceiling for standard
  H.264 ingest unless the current guidelines say otherwise.
- Audio: AAC, stereo, commonly up to 160 kbps.
- Transcoding (quality options for viewers) is not guaranteed for every channel; without it,
  viewers on slow connections get only the source quality, which argues for a moderate bitrate.
- **Enhanced Broadcasting** (OBS 30.1+ "multitrack video"): OBS encodes several renditions on the
  streamer's GPU and Twitch serves them as quality options. It started in January 2024 as a beta
  with NVIDIA GPUs on Windows and expanded later. It adds HEVC ingest and higher resolutions (2K
  beta). Requirements, codecs (AV1 status) and total bitrate are controlled by Twitch's server
  config and changed several times: check the help article before advising. It needs extra GPU
  encoder capacity because it runs several encodes at once.

## Kick

Checked 2026-11-21 against help.kick.com/en/articles/7066931-how-to-stream-on-kick-com.

- Bitrate 1000-8000 kbps; maximum 8000 kbps.
- Max resolution 1920x1080; max 60 fps.
- H.264 only (no HEVC/AV1). CBR only (VBR not supported). Keyframe interval 2 s.
- Audio: stereo, maximum 48 kHz (no bitrate stated; 160 kbps AAC is a safe choice).
- Kick's suggested x264: preset veryfast, profile main, tune zerolatency.
- Kick's suggested NVENC/AMD: P6 Slower, Tuning Ultra Low Latency, Single Pass, profile main.
  These are Kick's defaults, not hard requirements; high quality tuning and profile high also work
  with H.264 ingest. If the user sees stutter, Kick suggests x264 superfast or NVENC/AMD P3.
- Rescale to 1920x1080 when the base resolution is above 1080p.

## Local recording

Based on the OBS knowledge base recording guides (see `sources.md`).

- **Container:** MKV is crash-safe; remux to MP4 with File > Remux Recordings. Recent OBS versions
  add Hybrid MP4/MOV, which stay readable after a crash. Plain MP4/MOV are lost if OBS crashes
  mid-recording.
- **Rate control:** quality-based (CQP/CQ for NVENC, CQP for AMF, ICQ for QSV, CRF for x264,
  quality slider for Apple VT) rather than CBR. Starting points: NVENC CQ 18-23, x264 CRF 16-23.
  Lower numbers mean bigger files and higher quality. Check the file size of a test recording.
- **Codec:** HEVC or AV1 save space at the same quality when available and the editor decodes them.
  H.264 is the most compatible for editing.
- **Keyframe interval:** 0 (auto) is fine. 1-2 s makes scrubbing in editors smoother.
- **Audio:** AAC 192-320 kbps, or lossless (FLAC/PCM in MKV/MOV) for editing. Use separate tracks
  (Advanced output) to split game, mic and voice chat.
- **FPS above 60:** costs proportional GPU and encoder load; only for footage that needs it
  (slow motion, high-FPS uploads, frame blending: see `encoders.md` section 11).
- **Disk:** high-quality 1440p60 CQ recordings can exceed 50-100 Mbps. Record to an SSD.
- **Stream + record:** "Same as stream" shares one encode (no extra cost, stream quality). A
  separate recording encoder doubles encoder work; check skipped frames when both run.
