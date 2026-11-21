# Sources to check when researching

Use web search to confirm current values before advising. Prefer the official pages below over
blogs. URLs were checked on 2026-11-21 unless marked otherwise. If a page will not load, say so
and fall back to the snapshot in `platforms.md`, clearly labeled as possibly outdated.

## OBS Studio

- Knowledge base index: https://obsproject.com/kb/
- Encoding Performance Troubleshooting: https://obsproject.com/kb/encoding-performance-troubleshooting
- Stream Connection Troubleshooting: https://obsproject.com/kb/stream-connection-troubleshooting
- GPU Selection Guide (laptops, multi-GPU): https://obsproject.com/kb/gpu-selection-guide
- Windows Gaming Features Troubleshooting: https://obsproject.com/kb/windows-gaming-features-troubleshooting
- Game Capture Troubleshooting: https://obsproject.com/kb/game-capture-troubleshooting
- Known Application Conflicts: https://obsproject.com/kb/known-conflicts
- Standard Recording Output Guide: https://obsproject.com/kb/standard-recording-output-guide
- Advanced Recording Settings Guide: https://obsproject.com/kb/advanced-recording-settings-guide
- Recording Encoder Presets Guide: https://obsproject.com/kb/recording-encoder-presets-guide
- Audio/Video Formats Guide: https://obsproject.com/kb/audio-video-formats-guide
- Hybrid MP4 & Hybrid MOV: https://obsproject.com/kb/hybrid-mp4
- Transcodes / Transcoding: https://obsproject.com/kb/transcodes-transcoding
- SRT / RIST / WHIP guides: https://obsproject.com/kb/srt-protocol-streaming-guide,
  https://obsproject.com/kb/rist-protocol-streaming-guide, https://obsproject.com/kb/whip-streaming-guide
- Release notes (new encoders, settings, minimum drivers): https://github.com/obsproject/obs-studio/releases
- Official log analyzer (not re-checked): https://obsproject.com/tools/analyzer

## Streaming platforms

- YouTube, "Choose live encoder settings, bitrates, and resolutions":
  https://support.google.com/youtube/answer/2853702
- Twitch Broadcasting Guidelines: https://help.twitch.tv/s/article/broadcasting-guidelines
  (needs JavaScript; automated fetches return an empty page, so use web search results or ask
  the user to open it)
- Twitch Enhanced Broadcasting: https://help.twitch.tv/s/article/multiple-encodes (same caveat);
  launch post: https://blog.twitch.tv/2024/01/08/introducing-the-enhanced-broadcasting-beta/
- Kick, "How to stream on Kick.com": https://help.kick.com/en/articles/7066931-how-to-stream-on-kick-com

## GPU vendors

- NVIDIA Video Encode and Decode GPU Support Matrix:
  https://developer.nvidia.com/video-encode-and-decode-gpu-support-matrix-new
- NVIDIA NVENC OBS guide: https://www.nvidia.com/en-us/geforce/guides/broadcasting-guide/
- NVIDIA NVENC Application Note (presets, tuning, features per generation):
  https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/nvenc-application-note/
- AMD Advanced Media Framework (AMF), codecs and wiki: https://github.com/GPUOpen-LibrariesAndSDKs/AMF
- Intel media driver, encode/decode support per GPU generation: https://github.com/intel/media-driver
- Apple VideoToolbox: https://developer.apple.com/documentation/videotoolbox

## Linux

- Hardware video acceleration (VA-API, NVENC, driver packages, `vainfo`):
  https://wiki.archlinux.org/title/Hardware_video_acceleration (community wiki, accurate and current)
- OBS Flatpak (runtime and NVIDIA extension notes): https://flathub.org/apps/com.obsproject.Studio

## Frame blending and high-FPS capture (community projects)

Not official OBS documentation; check the repositories for the current version.

- blur releases and README ("Config settings explained"): https://github.com/f0e/blur
- Smoothie (smoothie-rs); the current recipe format is `target/defaults.ini`:
  https://github.com/couleur-tweak-tips/smoothie-rs
- Couleur Tweak Tips video docs (Smoothie recipe, OBS high-FPS recording, blur vs. Smoothie):
  https://ctt.cx/video/ (community guide, partly older than the code; treat numbers as field
  reports)
- obs-vkcapture (Linux Vulkan/OpenGL game capture): https://github.com/nowrep/obs-vkcapture

## Search queries that work well

- `site:obsproject.com/kb <topic>`
- `"<GPU model>" NVENC AV1 support matrix`
- `Twitch broadcasting guidelines bitrate <current year>`
- `Twitch Enhanced Broadcasting requirements <GPU vendor>`
- `OBS <version> release notes <encoder>`
