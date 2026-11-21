#!/usr/bin/env python3
"""Analyze an OBS Studio log file and print a JSON summary.

Read-only: the log is opened for reading only and nothing is written to disk.
Standard library only. Python 3.8+.

Usage:
    python3 analyze_obs_log.py <path-to-obs-log.txt> [--goal blend] [--compact]

--goal blend: the recording is meant for frame blending (blur, Smoothie). FPS above 60 is then
expected, and the high-FPS recording settings are checked instead (references/encoders.md section 11).

The path may contain "~" or environment variables (%APPDATA%, $HOME); they are
expanded, so the redacted paths printed by find_obs_logs.* can be passed as-is.

Exit codes:
    0  analysis printed
    1  file missing or unreadable
    2  bad arguments (argparse)
    3  file does not look like an OBS log
"""

import argparse
import getpass
import json
import os
import re
import sys

# Percent of frames. OBS shows "Encoding overloaded" from ~0.1% skipped frames;
# below 0.5% viewers rarely notice, above 5% the output is visibly broken.
WARN_PCT = 0.5
CRIT_PCT = 5.0

TS_RE = re.compile(r"^\d{1,2}:\d{2}:\d{2}\.\d{3}: ?")
ENC_HEADER_RE = re.compile(r"^\[(?P<tag>[^\]]*?)[:\s]+['\"](?P<name>[^'\"]+)['\"]\]:?\s*settings:\s*$")
X264_LINE_RE = re.compile(r"^\[x264 encoder: '(?P<name>[^']+)'\] (?P<key>preset|profile|tune): ?(?P<val>.*)$")
AUDIO_TAG_RE = re.compile(r"aac|opus|audio|mp3|flac|pcm", re.I)
AUDIO_BITRATE_RE = re.compile(r"^\[(?P<tag>[^\]]*?)[:\s]+['\"](?P<name>[^'\"]+)['\"]\]:?\s*bitrate:\s*(?P<br>\d+)")
LIBFDK_RE = re.compile(r"^libfdk_aac bitrate: (?P<br>\d+)")
KV_RE = re.compile(r"^\s+(?P<key>[A-Za-z0-9_\- ()/]+?):\s*(?P<val>.*?)\s*$")
OUTPUT_RE = re.compile(r"^Output '(?P<name>[^']+)': (?P<msg>.*)$")
TOTAL_RE = re.compile(r"^Total frames output: (?P<a>\d+)(?: \((?P<b>\d+) attempted\))?")
DRAWN_RE = re.compile(r"^Total drawn frames: (?P<a>\d+)(?: \((?P<b>\d+) attempted\))?")
LAGGED_RE = re.compile(r"^Number of lagged frames due to rendering lag/stalls: (?P<n>\d+) \((?P<p>[\d.]+)%\)")
DROPPED_RE = re.compile(r"^Number of dropped frames due to insufficient bandwidth/connection stalls: (?P<n>\d+) \((?P<p>[\d.]+)%\)")
SKIPPED_RE = re.compile(r"number of skipped frames due to encoding lag: (?P<n>\d+)/(?P<t>\d+) \((?P<p>[\d.]+)%\)")
START_MARKER_RE = re.compile(r"^==== (Streaming|Recording|Replay Buffer|Virtual Camera) Start ")
CONTAINER_RE = re.compile(r"""['"][^'"]*?\.(?P<ext>mkv|mp4|mov|flv|ts|m3u8)['"]""", re.I)
CONGESTION_RE = re.compile(r"Congestion detected|dropping bitrate to", re.I)
DISCONNECT_RE = re.compile(r"Disconnected from|Reconnecting in|RTMP send error|Connection to .* failed|Socket error|WriteN, RTMP", re.I)
HW_ERR_RE = re.compile(r"(nvenc|amf|qsv|vaapi|videotoolbox).*(error|fail|unable|could not)|"
                       r"(error|fail|unable|could not).*(nvenc|amf|qsv|vaapi|videotoolbox)", re.I)
NOT_SUPPORTED_RE = re.compile(r"not supported|not available|not found", re.I)
GPU_LINE_RE = re.compile(
    r"^(Loading up (D3D11|OpenGL|Metal)|D3D11 loaded|OpenGL loaded|Metal loaded|Initialized EGL|Using EGL|"
    r"Adapter \d+:|Driver Version:|HAGS Status:|Hardware GPU Scheduler:|D3D11 GPU priority|\[obs-nvenc\] NVENC version|"
    r"NVENC|VAAPI|FFmpeg VAAPI|LIBVA_DRIVER_NAME|\[AMF\]|\[qsv|\[VideoToolbox|.*Blacklisted driver)"
)
LOADED_ADAPTER_RE = re.compile(r"^Loading up (?:D3D11|OpenGL|Metal) on adapter (?P<name>.+?)(?: \(\d+\))?$")
IGPU_RE = re.compile(r"intel|uhd|iris|radeon\(tm\) graphics|radeon graphics|vega \d+ graphics|\d{3}m graphics", re.I)
DGPU_RE = re.compile(r"nvidia|geforce|radeon rx|radeon pro|arc a\d|arc b\d", re.I)
HW_ENCODER_ID_RE = re.compile(r"nvenc|amf|qsv|videotoolbox|vaapi|apple vt|texture", re.I)
SLOW_PRESETS = {"p5", "p6", "p7", "slow", "slower", "veryslow", "placebo", "quality", "highquality"}

SYS_KEYS = (
    ("CPU Name: ", "cpu"),
    ("Windows Version: ", "os"),
    ("OS Name: ", "os"),
    ("OS Version: ", "os_version"),
    ("Kernel Version: ", "kernel"),
    ("Distribution: ", "distribution"),
    ("Session Type: ", "session_type"),
    ("Desktop Environment: ", "desktop"),
    ("Running as administrator: ", "running_as_admin"),
    ("Model Identifier: ", "hardware_model"),
    ("Hardware Model: ", "hardware_model"),
    ("Game Mode: ", "windows_game_mode"),
    ("Hardware GPU Scheduler: ", "windows_hags"),
)


def redact(text):
    """Strip personal data: home paths, the current username, emails, MAC/IP addresses, URL paths."""
    if not isinstance(text, str):
        return text
    text = re.sub(r"(?i)([A-Z]:[\\/]Users[\\/])[^\\/'\"]+", r"\1<user>", text)
    text = re.sub(r"(/home/|/Users/|/var/home/)[^/'\"\s]+", r"\1<user>", text)
    try:
        user = getpass.getuser()
    except Exception:  # getuser raises when no user database entry exists
        user = ""
    if len(user) >= 3:
        text = re.sub(re.escape(user), "<user>", text, flags=re.I)
    text = re.sub(r"[\w.+-]+@[\w-]+\.[\w.-]+", "<email>", text)
    text = re.sub(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b", "<mac>", text)
    text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<ip>", text)
    text = re.sub(r"\b(?:[0-9A-Fa-f]{1,4}:){4,7}[0-9A-Fa-f]{1,4}\b", "<ip>", text)
    # stream keys / SRT passphrases can sit in URL paths or query strings
    text = re.sub(r"((?:rtmps?|srt|rist|https?)://[^/?#\s'\"]+)[/?#][^\s'\"]*", r"\1/<redacted>", text)
    return text


def to_num(val):
    try:
        f = float(val)
    except (TypeError, ValueError):
        return val
    return int(f) if f.is_integer() else f


def encoder_family(tag):
    t = tag.lower()
    for key, fam in (("nvenc", "NVENC"), ("amf", "AMF"), ("qsv", "QuickSync"), ("videotoolbox", "VideoToolbox"),
                     ("vaapi", "VAAPI"), ("x264", "x264"), ("svt", "SVT-AV1"), ("aom", "AOM-AV1")):
        if key in t:
            return fam
    return tag.strip() or "unknown"


def encoder_role(name):
    n = name.lower()
    if "stream" in n:
        return "stream"
    if "record" in n or "replay" in n:
        return "recording"
    return "unknown"


def output_kind(name):
    n = name.lower()
    if "replay" in n:
        return "replay_buffer"
    if "virtualcam" in n or "virtual" in n:
        return "virtual_camera"
    if "stream" in n or "rtmp" in n or "whip" in n:
        return "stream"
    if "file" in n or "record" in n:
        return "recording"
    return "unknown"


def parse_fps(val):
    m = re.match(r"^(\d+)/(\d+)$", val or "")
    if m and int(m.group(2)):
        return to_num(round(int(m.group(1)) / int(m.group(2)), 3))
    return to_num(val) if val else None


def analyze(lines):
    res = {
        "obs_version": None,
        "system": {},
        "video": None,
        "video_resets": 0,
        "available_video_encoders": [],
        "hardware_encoder_notes": [],
        "encoders": [],
        "audio_encoders": [],
        "sessions": [],
        "gpu_driver_lines": [],
    }
    sysinfo = res["system"]
    adapters, loaded_adapter = [], None
    cur_video = cur_enc = None
    in_video_reset = False
    in_available = None  # None, "header", "video", "audio"
    latest = {}  # output name -> its most recent session
    pending = []  # sessions stopped but not yet given the shared skipped-frames line
    x264_pre = {}  # x264 logs preset/profile/tune on separate lines before "settings:"
    congestion, disconnects, hw_errors, missing, containers = 0, [], [], [], []
    iface = None
    stream_seen = False

    def session_for(name):
        if name not in latest:
            latest[name] = {"output": name, "kind": output_kind(name)}
            res["sessions"].append(latest[name])
        return latest[name]

    for raw in lines:
        line = TS_RE.sub("", raw.rstrip("\r\n"))
        s = line.strip()

        if cur_enc is not None:
            m = KV_RE.match(line)
            if m and line[:1] in ("\t", " "):
                cur_enc["settings"][m.group("key").strip()] = to_num(m.group("val"))
                continue
            cur_enc = None
        if in_video_reset:
            m = KV_RE.match(line)
            if m and line[:1] in ("\t", " "):
                cur_video[m.group("key").strip()] = m.group("val")
                continue
            in_video_reset = False
        if in_available:
            if s.startswith("Video Encoders"):
                in_available = "video"
                continue
            if s.startswith("Audio Encoders"):
                in_available = "audio"
                continue
            if s.startswith("- "):
                if in_available == "video":
                    res["available_video_encoders"].append(s[2:])
                continue
            in_available = None

        if res["obs_version"] is None and re.match(r"^OBS \d+\.\d+", s):
            res["obs_version"] = s[4:].strip()
            continue
        for key, label in SYS_KEYS:
            if s.startswith(key):
                sysinfo.setdefault(label, s[len(key):].strip())
        m = re.match(r"^Physical Cores: (\d+), Logical Cores: (\d+)", s)
        if m:
            sysinfo["cores_physical"], sysinfo["cores_logical"] = int(m.group(1)), int(m.group(2))
        m = re.match(r"^Physical Memory: (\d+)MB Total", s)
        if m:
            sysinfo["memory_total_mb"] = int(m.group(1))
        m = re.match(r"^Adapter \d+: (.+)$", s)
        if m:
            adapters.append(m.group(1))
        m = LOADED_ADAPTER_RE.match(s)
        if m:
            loaded_adapter = m.group("name")

        if s == "video settings reset:":
            cur_video = {}
            res["video"] = cur_video
            res["video_resets"] += 1
            in_video_reset = True
            continue
        if s == "Available Encoders:":
            in_available = "header"
            continue

        m = ENC_HEADER_RE.match(s)
        if m:
            tag, name = m.group("tag").strip(), m.group("name")
            codec = None
            if tag.startswith("VideoToolbox "):  # "[VideoToolbox <output>: 'h264']: settings:"
                tag, name, codec = "VideoToolbox", tag.split(" ", 1)[1], name
            cur_enc = {"name": name, "family": encoder_family(tag), "role": encoder_role(name), "settings": {},
                       "video_at_start": dict(cur_video) if cur_video else None, "_tag": tag}
            cur_enc["settings"].update(x264_pre.pop(name, {}))
            if codec:
                cur_enc["settings"]["codec"] = codec
            res["encoders"].append(cur_enc)
            continue
        m = X264_LINE_RE.match(s)
        if m:
            x264_pre.setdefault(m.group("name"), {})[m.group("key")] = m.group("val").strip()
            continue
        m = AUDIO_BITRATE_RE.match(s)
        if m and AUDIO_TAG_RE.search(m.group("tag")):
            res["audio_encoders"].append({"name": m.group("name"), "encoder": m.group("tag").strip(),
                                          "bitrate_kbps": int(m.group("br"))})
            continue
        m = LIBFDK_RE.match(s)
        if m:
            res["audio_encoders"].append({"name": "libfdk_aac", "encoder": "libfdk_aac",
                                          "bitrate_kbps": int(m.group("br"))})
            continue

        if START_MARKER_RE.match(s):
            stream_seen = stream_seen or s.startswith("==== Streaming")
            pending.clear()
            continue

        m = OUTPUT_RE.match(s)
        if m:
            name, msg = m.group("name"), m.group("msg")
            if msg == "stopping":  # first line of each output's stats block
                latest.pop(name, None)
                pending.append(session_for(name))
                continue
            if msg.startswith("Reconnecting in"):
                disconnects.append(redact(s))
                continue
            sess = session_for(name)
            for rx, a, b in ((TOTAL_RE, "total_frames_output", "total_frames_attempted"),
                             (DRAWN_RE, "drawn_frames", "drawn_frames_attempted")):
                mm = rx.match(msg)
                if mm:
                    sess[a] = int(mm.group("a"))
                    if mm.group("b"):
                        sess[b] = int(mm.group("b"))
            mm = LAGGED_RE.match(msg)
            if mm:
                sess["rendering_lagged_frames"], sess["rendering_lagged_pct"] = int(mm.group("n")), float(mm.group("p"))
            mm = DROPPED_RE.match(msg)
            if mm:
                sess["network_dropped_frames"], sess["network_dropped_pct"] = int(mm.group("n")), float(mm.group("p"))
            continue

        m = SKIPPED_RE.search(s)
        if m:
            # one video pipeline feeds every output, so the count applies to all outputs stopped together
            targets = list(pending)
            if not targets:
                targets = [{"output": "unknown", "kind": "unknown"}]
                res["sessions"].append(targets[0])
            for t in targets:
                t["encoder_skipped_frames"] = int(m.group("n"))
                t["encoder_skipped_of"] = int(m.group("t"))
                t["encoder_skipped_pct"] = float(m.group("p"))
            pending.clear()
            continue

        if "muxer" in s.lower() or "Writing file" in s or "Wrote replay buffer" in s:
            mm = CONTAINER_RE.search(s)
            if mm:
                containers.append(mm.group("ext").lower())
        m = re.search(r"\] Interface: .*\((?P<type>wireless|ethernet|[a-z]+), ", s)
        if m:
            iface = m.group("type")
        if CONGESTION_RE.search(s):
            congestion += 1
        if DISCONNECT_RE.search(s):
            disconnects.append(redact(s))
        if s.startswith("Encoder ID '") and "not found" in s:
            missing.append(s)
        elif HW_ERR_RE.search(s) and not NOT_SUPPORTED_RE.search(s):
            hw_errors.append(redact(s))
        if re.search(r"NVENC version|AV1 supported|encoding not supported|LIBVA_DRIVER_NAME", s):
            res["hardware_encoder_notes"].append(redact(s))
        if GPU_LINE_RE.match(s) and len(res["gpu_driver_lines"]) < 40:
            entry = redact(s)
            if entry not in res["gpu_driver_lines"]:
                res["gpu_driver_lines"].append(entry)

    # audio encoders that log a "settings:" block (e.g. CoreAudio AAC on macOS)
    for e in [e for e in res["encoders"] if AUDIO_TAG_RE.search(e["_tag"])]:
        res["encoders"].remove(e)
        res["audio_encoders"].append({"name": e["name"], "encoder": e["_tag"],
                                      "bitrate_kbps": to_num(str(e["settings"].get("bitrate", "")).split(" ")[0]) or None})
    for e in res["encoders"]:
        del e["_tag"]

    res["sessions"] = [x for x in res["sessions"] if len(x) > 2]  # drop sessions with no stats
    res["recording_containers"] = sorted(set(containers))
    res["network_events"] = {"interface_type": iface, "congestion_events": congestion, "disconnect_count": len(disconnects),
                             "disconnect_lines": disconnects[:20]}
    res["missing_encoders"] = sorted(set(missing))
    res["hardware_encoder_errors"] = hw_errors[:20]
    res["_adapters"], res["_loaded_adapter"], res["_stream_seen"] = adapters, loaded_adapter, stream_seen
    return res


def pick_primary(encoders):
    for role in ("stream", "recording", "unknown"):
        for e in reversed(encoders):
            if e["role"] == role:
                return e
    return None


def keyint_seconds(enc, fps):
    st = enc["settings"]
    k = st.get("keyint")
    if isinstance(k, str):
        m = re.match(r"^\s*([\d.]+)\s*\(?s\)?", k)  # VideoToolbox logs seconds, e.g. "2 (s)"
        return float(m.group(1)) if m else None
    if isinstance(st.get("fps_num"), (int, float)) and st.get("fps_den"):
        fps = st["fps_num"] / st["fps_den"]
    if isinstance(k, (int, float)) and isinstance(fps, (int, float)) and fps:
        return round(k / fps, 2)
    return None


def slow_at_high_fps(st):
    """Encoder settings that cost time per frame; references/encoders.md section 11 turns them off."""
    found = []
    if str(st.get("preset", "")).lower().replace(" ", "") in SLOW_PRESETS:
        found.append(f"preset {st['preset']}")
    mp = str(st.get("multipass", "")).lower()
    if mp and mp not in ("disabled", "off", "false", "0"):
        found.append(f"multipass {st['multipass']}")
    if str(st.get("lookahead", "")).lower().startswith("true"):
        found.append("look-ahead on")
    bf = st.get("b-frames", st.get("bf"))
    if isinstance(bf, (int, float)) and bf > 0:
        found.append(f"{bf} B-frames")
    return found


def problem(res, pid, severity, evidence, meaning, fixes):
    res["problems"].append({"id": pid, "severity": severity, "evidence": evidence,
                            "meaning": meaning, "fix_hints": fixes})


def diagnose(res, goal=None):
    res["problems"] = []
    sessions = res["sessions"]
    video = res["video"] or {}
    fps = parse_fps(video.get("fps"))
    primary = pick_primary(res["encoders"])

    def worst(key):
        vals = [x[key] for x in sessions if key in x]
        return max(vals) if vals else None

    sk, rl, dr = worst("encoder_skipped_pct"), worst("rendering_lagged_pct"), worst("network_dropped_pct")
    res["summary"] = {
        "encoder_in_use": None if not primary else {
            "name": primary["name"], "family": primary["family"], "role": primary["role"],
            "codec": primary["settings"].get("codec"), "rate_control": primary["settings"].get("rate_control"),
            "bitrate_kbps": primary["settings"].get("bitrate"), "preset": primary["settings"].get("preset"),
        },
        "base_resolution": video.get("base resolution"),
        "output_resolution": video.get("output resolution"),
        "downscale_filter": video.get("downscale filter"),
        "fps": fps,
        "goal": goal,
        "sessions_analyzed": len(sessions),
        "worst_network_dropped_pct": dr,
        "worst_encoder_skipped_pct": sk,
        "worst_rendering_lagged_pct": rl,
        "total_rendering_lagged_frames": sum(x.get("rendering_lagged_frames", 0) for x in sessions),
    }

    if not sessions:
        problem(res, "no_output_session", "info", "No stream or recording was stopped in this log.",
                "OBS writes frame statistics only when an output stops, so there is nothing to measure yet.",
                ["Record or stream 2-3 minutes of real gameplay, stop it, then analyze the newest log."])

    if sk is not None and sk >= WARN_PCT:
        fam = primary["family"] if primary else "unknown"
        hints = ["Lower output resolution or FPS: encoder load scales with pixels per second.",
                 "Use a faster preset; on hardware encoders turn off multipass and look-ahead first."]
        if fam == "x264":
            hints.insert(0, "x264 runs on the CPU: switch to a hardware encoder if one is in available_video_encoders.")
        if rl is not None and rl >= WARN_PCT:
            hints.append("Rendering lag is high too: a GPU-bound game also starves GPU encoders. Cap the game's FPS.")
        problem(res, "encoder_overloaded", "critical" if sk >= CRIT_PCT else "warning",
                f"{sk}% of frames skipped due to encoding lag (encoder {fam}, preset "
                f"{primary['settings'].get('preset') if primary else None}).",
                "The encoder cannot keep up with resolution x FPS at this preset ('Encoding overloaded').", hints)

    if rl is not None and rl >= WARN_PCT:
        hints = ["Cap the game's frame rate (in-game limiter or V-Sync) to leave GPU headroom for OBS.",
                 "Lower OBS base/output resolution or FPS; remove heavy browser sources, filters and preview scaling."]
        if str(res["system"].get("running_as_admin", "")).lower() == "false":
            hints.insert(0, "Run OBS as administrator (Windows) so it gets GPU scheduling priority.")
        problem(res, "rendering_lag", "critical" if rl >= CRIT_PCT else "warning",
                f"{rl}% of frames lagged due to rendering lag/stalls.",
                "OBS could not render frames in time: the GPU is overloaded, usually by the game.", hints)

    ne = res["network_events"]
    if dr is not None and dr >= WARN_PCT:
        hints = ["Lower video bitrate to about 70-80% of measured sustained upload.",
                 "Use wired Ethernet instead of Wi-Fi; pick a closer or different ingest server.",
                 "Consider Dynamic Bitrate (Settings > Advanced > Network)."]
        if ne["interface_type"] == "wireless":
            hints.insert(0, "The stream ran over Wi-Fi: Wi-Fi is the most common cause of dropped frames. Try Ethernet first.")
        problem(res, "network_dropped_frames", "critical" if dr >= CRIT_PCT else "warning",
                f"{dr}% of frames dropped due to insufficient bandwidth/connection stalls.",
                "The connection to the ingest server could not sustain the bitrate. This is not a PC performance problem.",
                hints)

    if ne["congestion_events"]:
        problem(res, "bitrate_congestion", "warning", f"{ne['congestion_events']} congestion / bitrate-drop events.",
                "OBS lowered the bitrate because the upload could not keep up.",
                ["Set a lower base bitrate so dynamic bitrate rarely has to step in."])
    if ne["disconnect_count"]:
        problem(res, "stream_disconnects", "warning", f"{ne['disconnect_count']} disconnect/reconnect/socket-error lines.",
                "The stream connection was interrupted.",
                ["Check Wi-Fi vs Ethernet, router/ISP stability, firewall/antivirus; try another ingest server."])

    for line in res["missing_encoders"]:
        problem(res, "configured_encoder_missing", "critical", line,
                "The profile uses an encoder OBS could not load (driver missing or broken, GPU changed, or OBS build without it).",
                ["Update or reinstall the GPU driver, then re-check Settings > Output > Encoder.",
                 "Linux: make sure the OBS package (distro/Flatpak) includes NVENC/VAAPI support."])
    if res["hardware_encoder_errors"]:
        problem(res, "hardware_encoder_error", "critical", res["hardware_encoder_errors"][0],
                "A hardware encoder failed to initialize or errored while encoding.",
                ["Update the GPU driver; close other apps using the encoder; check consumer GPU session limits."])

    la = res.pop("_loaded_adapter")
    adapters = res.pop("_adapters")
    if la and IGPU_RE.search(la) and any(DGPU_RE.search(a) for a in adapters):
        problem(res, "obs_on_integrated_gpu", "warning", f"OBS renders on '{la}' while a dedicated GPU is present.",
                "On hybrid-GPU laptops OBS should run on the GPU that renders the game, or capture is slow or black.",
                ["Windows: Settings > System > Display > Graphics: set OBS to the GPU the game uses. See the OBS GPU Selection Guide."])

    for e in res["encoders"]:
        st = e["settings"]
        if e["role"] == "stream":
            rc = str(st.get("rate_control", "")).upper()
            if rc and rc != "CBR":
                problem(res, "stream_not_cbr", "warning", f"Stream encoder '{e['name']}' uses {rc}.",
                        "Twitch, YouTube and Kick ask for CBR; VBR/CQP spikes cause drops and buffering.",
                        ["Set Rate Control to CBR for the streaming encoder."])
            ks = keyint_seconds(e, fps)
            if ks is not None and ks > 2.05:
                problem(res, "stream_keyframe_interval", "warning",
                        f"Stream encoder '{e['name']}' keyframe interval is about {ks}s.",
                        "Platforms expect 2 s keyframes; 0/auto usually gives longer intervals.",
                        ["Set Keyframe Interval to 2 s."])
        if str(st.get("lookahead", "")).lower().startswith("true") and sk is not None and sk >= WARN_PCT:
            problem(res, "lookahead_under_load", "info", f"Look-ahead is on for '{e['name']}' while frames are skipped.",
                    "Look-ahead costs encoder time.", ["Turn off look-ahead first when the encoder is overloaded."])

    stream_seen = res.pop("_stream_seen") or any(x["kind"] == "stream" for x in sessions)
    if isinstance(fps, (int, float)) and fps > 60 and (goal != "blend" or stream_seen):
        problem(res, "fps_above_60", "warning" if stream_seen else "info", f"Canvas FPS is {fps}.",
                "Streaming platforms accept at most 60 FPS. For recordings every frame above 60 adds GPU and encoder load.",
                ["Use 60 FPS (or 30) unless you need high-FPS recordings and have measured headroom."])

    hw = [x for x in res["available_video_encoders"] if HW_ENCODER_ID_RE.search(x)]
    if primary and primary["family"] == "x264" and hw:
        problem(res, "x264_with_hw_available", "info",
                f"x264 (CPU) in use while hardware encoders are available: {', '.join(hw[:4])}.",
                "x264 competes with the game for CPU time; on a gaming PC a hardware encoder is usually the better choice.",
                ["Try the hardware encoder; keep x264 only with large CPU headroom."])

    if goal == "blend":
        diagnose_blend(res, fps, video, sk)
    return res


def diagnose_blend(res, fps, video, sk):
    """Checks for recordings meant for frame blending (blur, Smoothie)."""
    if isinstance(fps, (int, float)):
        if fps < 120:
            problem(res, "blend_fps_low", "warning", f"Canvas FPS is {fps}.",
                    "Frame blending needs several real frames per output frame. Below 120 fps the blur tool has to "
                    "interpolate most of them, which smears fast motion and HUDs.",
                    ["Record at 120-240+ fps if the game reaches it (Settings > Video > Fractional FPS Value, e.g. 240/1).",
                     "Otherwise expect artifacts, or use RIFE pre-interpolation in blur/Smoothie (much slower)."])
        elif fps % 60:
            problem(res, "blend_fps_uneven", "info", f"Canvas FPS is {fps}, not a multiple of 60.",
                    "Recorded frames do not split evenly into 60 fps output frames, so the blur strength varies "
                    "slightly from frame to frame.",
                    ["Use 120, 180, 240, 300 or 360 fps (Fractional FPS Value, Denominator 1), "
                     "or interpolate to a multiple of the output FPS (blur/Smoothie 'fps: 5x' style values)."])
    fmt = str(video.get("format", ""))
    if fmt and fmt.upper() != "NV12":
        problem(res, "blend_color_format", "info", f"Color format is {fmt}.",
                "Formats other than NV12 cost more encoder time. Smoothie's SVP interpolation takes a slower path "
                "with I444, and its RIFE pre-interpolation can crash with some formats.",
                ["Settings > Advanced > Video: Color Format NV12, Color Range Limited, unless you need HDR or 4:4:4."])
    for e in res["encoders"]:
        if e["role"] != "recording":
            continue
        st = e["settings"]
        rc = str(st.get("rate_control", "")).upper()
        if rc in ("CBR", "VBR", "ABR"):
            problem(res, "blend_bitrate_rate_control", "info", f"Recording encoder '{e['name']}' uses {rc}.",
                    "A bitrate target is spread over every frame. At high FPS each frame gets little, and fast "
                    "motion turns blocky before it is blended into every output frame.",
                    ["Use quality-based rate control: CQP (NVENC, AMF), ICQ (QuickSync), CRF (x264)."])
        slow = slow_at_high_fps(st)
        if slow and isinstance(fps, (int, float)) and fps > 120:
            problem(res, "blend_slow_encoder_settings", "warning" if sk is not None and sk >= WARN_PCT else "info",
                    f"Recording encoder '{e['name']}' at {fps} fps: {', '.join(slow)}.",
                    "These settings cost encoder time per frame. At high FPS they are the usual cause of skipped "
                    "frames, which make the blurred video stutter.",
                    ["Fast preset (NVENC P1-P4, AMF Speed/Balanced), single pass, look-ahead off, Max B-frames 0."])


def main(argv=None):
    ap = argparse.ArgumentParser(description="Analyze an OBS Studio log file (read-only) and print JSON.")
    ap.add_argument("log", help="path to an OBS log .txt file (~ and environment variables are expanded)")
    ap.add_argument("--goal", choices=["blend"],
                    help="blend: recording for frame blending (blur, Smoothie); checks high-FPS recording settings")
    ap.add_argument("--compact", action="store_true", help="print single-line JSON")
    args = ap.parse_args(argv)

    path = os.path.expanduser(os.path.expandvars(args.log))
    if not os.path.isfile(path):
        print(f"error: log file not found: {redact(path)}", file=sys.stderr)
        return 1
    try:
        with open(path, "r", encoding="utf-8-sig", errors="replace") as fh:
            lines = fh.readlines()
    except OSError as exc:
        print(f"error: cannot read log file: {redact(str(exc))}", file=sys.stderr)
        return 1

    head = "".join(lines[:400])
    if not re.search(r"OBS \d+\.\d+|Available Encoders:|video settings reset:", head):
        print("error: this does not look like an OBS Studio log (no OBS version or startup lines found).",
              file=sys.stderr)
        return 3

    res = diagnose(analyze(lines), args.goal)
    # most useful keys first; the rest keeps parse order
    out = {"log_file": redact(os.path.basename(path)), "obs_version": res.pop("obs_version"),
           "summary": res.pop("summary"), "problems": res.pop("problems"), **res}
    print(json.dumps(out,
                     indent=None if args.compact else 2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
