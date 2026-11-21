"""Tests for analyze_obs_log.py. Run: python3 -m unittest discover -s tests"""

import importlib.util
import io
import json
import os
import unittest
from contextlib import redirect_stderr, redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
SCRIPT = os.path.join(HERE, "..", "skills", "obs-settings-advisor", "scripts", "analyze_obs_log.py")

spec = importlib.util.spec_from_file_location("analyze_obs_log", SCRIPT)
alog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alog)


def run(name):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = alog.main([os.path.join(FIX, name)])
    return code, (json.loads(out.getvalue()) if out.getvalue() else None), err.getvalue()


def problem_ids(data):
    return {p["id"]: p["severity"] for p in data["problems"]}


class WindowsNvencStream(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.code, cls.d, _ = run("windows_nvenc_stream_wifi.txt")

    def test_exit_ok(self):
        self.assertEqual(self.code, 0)

    def test_summary(self):
        s = self.d["summary"]
        self.assertEqual(self.d["obs_version"], "31.0.2 (64-bit, windows)")
        self.assertEqual(s["encoder_in_use"]["family"], "NVENC")
        self.assertEqual(s["encoder_in_use"]["role"], "stream")
        self.assertEqual(s["encoder_in_use"]["bitrate_kbps"], 6000)
        self.assertEqual(s["output_resolution"], "1920x1080")
        self.assertEqual(s["fps"], 60)
        self.assertEqual(s["worst_network_dropped_pct"], 2.9)
        self.assertEqual(s["total_rendering_lagged_frames"], 1390)

    def test_sessions(self):
        kinds = sorted(x["kind"] for x in self.d["sessions"])
        self.assertEqual(kinds, ["recording", "stream"])
        stream = next(x for x in self.d["sessions"] if x["kind"] == "stream")
        self.assertEqual(stream["network_dropped_frames"], 3120)
        self.assertEqual(stream["encoder_skipped_frames"], 54)

    def test_problems(self):
        ids = problem_ids(self.d)
        self.assertEqual(ids.get("network_dropped_frames"), "warning")
        self.assertEqual(ids.get("rendering_lag"), "warning")
        self.assertIn("stream_disconnects", ids)
        self.assertNotIn("encoder_overloaded", ids)
        drop = next(p for p in self.d["problems"] if p["id"] == "network_dropped_frames")
        self.assertIn("Wi-Fi", drop["fix_hints"][0])
        lag = next(p for p in self.d["problems"] if p["id"] == "rendering_lag")
        self.assertIn("administrator", lag["fix_hints"][0])

    def test_network(self):
        ne = self.d["network_events"]
        self.assertEqual(ne["interface_type"], "wireless")
        self.assertEqual(ne["disconnect_count"], 3)

    def test_containers_and_privacy(self):
        self.assertEqual(self.d["recording_containers"], ["mkv"])
        blob = json.dumps(self.d)
        self.assertNotIn("JaneDoe", blob)
        self.assertNotIn("/app", blob.replace("live-video.net/<redacted>", ""))


class MacX264Overloaded(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.code, cls.d, _ = run("macos_x264_overloaded.txt")

    def test_encoder(self):
        enc = self.d["summary"]["encoder_in_use"]
        self.assertEqual(enc["family"], "x264")
        self.assertEqual(enc["preset"], "medium")
        self.assertEqual(enc["rate_control"], "VBR")

    def test_problems(self):
        ids = problem_ids(self.d)
        self.assertEqual(ids.get("encoder_overloaded"), "critical")
        self.assertIn("stream_not_cbr", ids)
        self.assertIn("stream_keyframe_interval", ids)
        self.assertIn("x264_with_hw_available", ids)

    def test_audio_settings_block(self):
        self.assertEqual(self.d["audio_encoders"][0]["bitrate_kbps"], 160)
        self.assertEqual(len(self.d["encoders"]), 1)  # CoreAudio must not count as a video encoder


class LinuxReplay240(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.code, cls.d, _ = run("linux_nvenc_replay_240fps.txt")

    def test_numbers(self):
        s = self.d["summary"]
        self.assertEqual(s["fps"], 240)
        self.assertEqual(s["worst_encoder_skipped_pct"], 98.9)
        self.assertEqual(s["worst_rendering_lagged_pct"], 59.3)
        self.assertEqual(self.d["sessions"][0]["kind"], "replay_buffer")

    def test_problems(self):
        ids = problem_ids(self.d)
        self.assertEqual(ids.get("encoder_overloaded"), "critical")
        self.assertEqual(ids.get("rendering_lag"), "critical")
        self.assertEqual(ids.get("fps_above_60"), "info")  # recording only, not streaming
        self.assertIn("lookahead_under_load", ids)

    def test_privacy(self):
        self.assertNotIn("janedoe", json.dumps(self.d))


class Errors(unittest.TestCase):
    def test_not_obs_log(self):
        code, data, err = run("not_an_obs_log.txt")
        self.assertEqual(code, 3)
        self.assertIsNone(data)
        self.assertIn("does not look like", err)

    def test_missing_file(self):
        code, _, err = run("does_not_exist.txt")
        self.assertEqual(code, 1)
        self.assertIn("not found", err)


class Redaction(unittest.TestCase):
    def test_redact(self):
        r = alog.redact
        self.assertEqual(r("C:\\Users\\Jane\\Videos"), "C:\\Users\\<user>\\Videos")
        self.assertEqual(r("C:/Users/Jane/Videos"), "C:/Users/<user>/Videos")
        self.assertEqual(r("/home/jane/x"), "/home/<user>/x")
        self.assertEqual(r("/Users/jane/x"), "/Users/<user>/x")
        self.assertEqual(r("bind 192.168.1.20 ok"), "bind <ip> ok")
        self.assertEqual(r("mac aa:bb:cc:dd:ee:ff"), "mac <mac>")
        self.assertEqual(r("srt://host:9000?streamid=secret"), "srt://host:9000/<redacted>")
        self.assertEqual(r("mail jane@example.com"), "mail <email>")


if __name__ == "__main__":
    unittest.main()
