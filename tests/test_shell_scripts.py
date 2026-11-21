"""Run the bash scripts and check their JSON. Skipped on Windows. Run: python3 -m unittest discover -s tests"""

import json
import os
import platform
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..", "skills", "obs-settings-advisor", "scripts")
MOCK_MAC = os.path.join(HERE, "mock_macos")
BASH = shutil.which("bash")


def run(script, env=None):
    p = subprocess.run([BASH, os.path.join(SCRIPTS, script)], capture_output=True, text=True, env=env, timeout=120)
    return p.returncode, p.stdout, p.stderr


@unittest.skipIf(platform.system() == "Windows" or not BASH, "bash scripts are for macOS/Linux")
class DetectHardware(unittest.TestCase):
    def test_real_machine(self):
        code, out, err = run("detect_hardware.sh")
        self.assertEqual(code, 0, err)
        d = json.loads(out)
        for key in ("os", "cpu", "memory", "gpus", "displays", "obs", "warnings"):
            self.assertIn(key, d)
        self.assertIn(d["os"]["platform"], ("linux", "macos"))
        home = os.path.expanduser("~")
        if len(home) > 1:
            self.assertNotIn(home, out)

    @unittest.skipIf(platform.system() == "Darwin", "mock is for exercising the macOS branch elsewhere")
    def test_mocked_macos(self):
        env = dict(os.environ, PATH=MOCK_MAC + os.pathsep + os.environ.get("PATH", ""))
        code, out, err = run("detect_hardware.sh", env)
        self.assertEqual(code, 0, err)
        d = json.loads(out)
        self.assertEqual(d["os"]["platform"], "macos")
        self.assertEqual(d["cpu"]["performance_cores"], 8)
        self.assertEqual(d["memory"]["total_mb"], 16384)
        self.assertTrue(d["machine"]["is_laptop"])
        gpu = d["gpus"][0]
        self.assertEqual(gpu["vendor"], "Apple")
        self.assertEqual(gpu["hw_encoder"]["api"], "VideoToolbox")
        self.assertEqual(gpu["hw_encoder"]["codecs"], ["h264", "hevc"])
        self.assertEqual([x["resolution"] for x in d["displays"]], ["3456x2234", "3840x2160"])
        self.assertEqual(d["displays"][1]["refresh_hz"], 60)
        self.assertNotIn("SERIAL", out)


@unittest.skipIf(platform.system() == "Windows" or not BASH, "bash scripts are for macOS/Linux")
class FindObsLogs(unittest.TestCase):
    def test_finds_newest_and_redacts(self):
        with tempfile.TemporaryDirectory() as home:
            sub = ("Library/Application Support/obs-studio/logs" if platform.system() == "Darwin"
                   else ".config/obs-studio/logs")
            logdir = os.path.join(home, sub)
            os.makedirs(logdir)
            for i, name in enumerate(["2026-01-01 10-00-00.txt", "2026-01-02 10-00-00.txt",
                                      "2026-01-03 10-00-00.txt", "2026-01-04 10-00-00.txt"]):
                path = os.path.join(logdir, name)
                with open(path, "w") as fh:
                    fh.write("Output 'simple_stream': stopping\n" if i == 0 else "OBS 31.0.0\n")
                os.utime(path, (1700000000 + i * 100, 1700000000 + i * 100))
            env = dict(os.environ, HOME=home)
            env.pop("XDG_CONFIG_HOME", None)
            code, out, err = run("find_obs_logs.sh", env)
            self.assertEqual(code, 0, err)
            d = json.loads(out)
            self.assertEqual(len(d["logs"]), 3)
            self.assertTrue(d["logs"][0]["path"].startswith("~/"))
            self.assertTrue(d["logs"][0]["path"].endswith("2026-01-04 10-00-00.txt"))
            self.assertTrue(d["newest_log_with_output_stats"].endswith("2026-01-01 10-00-00.txt"))
            self.assertNotIn(home, out)

    def test_no_logs_exit_1(self):
        with tempfile.TemporaryDirectory() as home:
            env = dict(os.environ, HOME=home)
            env.pop("XDG_CONFIG_HOME", None)
            code, out, err = run("find_obs_logs.sh", env)
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(out)["logs"], [])
            self.assertIn("no OBS log files found", err)


if __name__ == "__main__":
    unittest.main()
