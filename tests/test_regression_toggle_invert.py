"""Regression tests for bin/omarchy-toggle-invert.

Each test names the bug it pins. The CLI is run as a subprocess against a stub
hyprctl so the exact module call is observable and no live Hyprland is touched.
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


class ToggleInvertRegressionCase(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="invert-reg-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.state = self.tmp / "state"
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.log = self.tmp / "hyprctl.log"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        stub = self.bin / "hyprctl"
        stub.write_text('#!/bin/bash\necho "$*" >> "$HYPRCTL_LOG"\nexit 0\n')
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

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

    def test_status_is_per_mode_not_global(self):
        # Bug pinned: a "window=true" line made "desktop --status" report enabled.
        self.write_status("desktop=false\nwindow=true\n")
        self.assertEqual(json.loads(self.run_cli("desktop", "--status").stdout)["enabled"],
                         False)

    def test_default_action_is_toggle_not_set(self):
        # Bug pinned: omitting the action defaulted to turning the mode on.
        self.assertEqual(self.run_cli("window").returncode, 0)
        self.assertIn("toggle('window')", self.calls())
        self.assertNotIn("set('window', true)", self.calls())

    def test_invalid_mode_is_validated_before_dispatch(self):
        # Bug pinned: a bad mode fell through and reached hyprctl.
        proc = self.run_cli("monitor", "on")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Usage:", proc.stderr)
        self.assertEqual(self.calls(), "")

    def test_mode_argument_is_passed_through_verbatim(self):
        # Bug pinned: window actions were dispatched with the desktop mode hard-coded.
        self.assertEqual(self.run_cli("window", "off").returncode, 0)
        self.assertIn("set('window', false)", self.calls())
        self.assertNotIn("desktop", self.calls())

    def test_status_does_not_touch_hyprctl_or_the_state_dir(self):
        # Bug pinned: reading status created the state dir and called the compositor.
        self.assertEqual(self.run_cli("desktop", "--status").returncode, 0)
        self.assertEqual(self.calls(), "")
        self.assertFalse((self.state / "omarchy").exists())


if __name__ == "__main__":
    unittest.main()