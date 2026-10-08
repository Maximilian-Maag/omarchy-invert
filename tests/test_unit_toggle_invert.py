"""Unit tests: bin/omarchy-toggle-invert's argument handling and state readout.

The CLI is a bash script, so it is exercised as a subprocess with stub hyprctl
and a temporary XDG_STATE_HOME. A log-only hyprctl makes the exact command the
module would receive observable; no live compositor is involved.
"""
import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parent.parent
CLI = REPO / "bin/omarchy-toggle-invert"


def write_stub(path, body):
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


class ToggleInvertUnitCase(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="invert-unit-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.state = self.tmp / "state"
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.log = self.tmp / "hyprctl.log"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        write_stub(self.bin / "hyprctl",
                   '#!/bin/bash\necho "$*" >> "$HYPRCTL_LOG"\nexit 0\n')

    def run_cli(self, *args):
        env = dict(os.environ)
        env["HOME"] = str(self.home)
        env["XDG_STATE_HOME"] = str(self.state)
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        env["HYPRCTL_LOG"] = str(self.log)
        return subprocess.run(["bash", str(CLI), *args], env=env, cwd=str(REPO),
                              capture_output=True, text=True)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def write_status(self, text):
        (self.state / "omarchy").mkdir(parents=True, exist_ok=True)
        (self.state / "omarchy/invert.status").write_text(text)

    # ── dispatch ──────────────────────────────────────────────────────────
    def test_every_mode_and_action_emits_the_module_call(self):
        cases = [
            (("desktop", "on"), "set('desktop', true)"),
            (("desktop", "off"), "set('desktop', false)"),
            (("desktop", "toggle"), "toggle('desktop')"),
            (("window", "on"), "set('window', true)"),
            (("window", "off"), "set('window', false)"),
            (("window", "toggle"), "toggle('window')"),
            (("window",), "toggle('window')"),          # default action is toggle
        ]
        for args, expected in cases:
            with self.subTest(args=args):
                if self.log.exists():
                    self.log.unlink()
                proc = self.run_cli(*args)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIn(f"require('Maximilian-Maag.invert').{expected}", self.calls())

    def test_a_set_action_creates_the_state_directory(self):
        self.assertFalse((self.state / "omarchy").exists())
        self.assertEqual(self.run_cli("desktop", "on").returncode, 0)
        self.assertTrue((self.state / "omarchy").is_dir())

    # ── validation ────────────────────────────────────────────────────────
    def test_invalid_mode_is_rejected_with_usage_and_no_dispatch(self):
        proc = self.run_cli("monitor", "on")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Usage:", proc.stderr)
        self.assertEqual(self.calls(), "")

    def test_missing_mode_is_rejected(self):
        proc = self.run_cli()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Usage:", proc.stderr)

    def test_invalid_action_is_rejected_with_usage(self):
        proc = self.run_cli("desktop", "blink")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Usage:", proc.stderr)
        self.assertEqual(self.calls(), "")

    # ── status readout ────────────────────────────────────────────────────
    def test_status_with_no_file_reports_disabled(self):
        proc = self.run_cli("desktop", "--status")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), {"mode": "desktop", "enabled": False})
        self.assertEqual(self.calls(), "")

    def test_status_does_not_create_the_state_directory(self):
        self.assertEqual(self.run_cli("window", "--status").returncode, 0)
        self.assertFalse((self.state / "omarchy").exists())

    def test_status_reads_only_the_requested_mode(self):
        self.write_status("desktop=false\nwindow=true\n")
        desktop = json.loads(self.run_cli("desktop", "--status").stdout)
        window = json.loads(self.run_cli("window", "--status").stdout)
        self.assertEqual(desktop, {"mode": "desktop", "enabled": False})
        self.assertEqual(window, {"mode": "window", "enabled": True})

    def test_status_true_when_the_mode_line_is_true(self):
        self.write_status("desktop=true\nwindow=false\n")
        self.assertEqual(json.loads(self.run_cli("desktop", "--status").stdout),
                         {"mode": "desktop", "enabled": True})


if __name__ == "__main__":
    unittest.main()