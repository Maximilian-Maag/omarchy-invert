"""Integration tests: bin/omarchy-toggle-invert round-tripping through Hyprland.

A stub hyprctl emulates the Lua module — it parses the dispatched expression and
rewrites the status file the CLI later reads back — so the full command -> module
-> state -> `--status` path is exercised. The user's real session is never used.
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

MODULE_STUB = r"""#!/bin/bash
# Emulates hypr/invert.lua: applies the dispatched set()/toggle() to the status file.
echo "$*" >> "$HYPRCTL_LOG"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
mkdir -p "$STATE_DIR"
f="$STATE_DIR/invert.status"
[ -f "$f" ] || printf 'desktop=false\nwindow=false\n' > "$f"
d=$(sed -n 's/^desktop=//p' "$f")
w=$(sed -n 's/^window=//p' "$f")
expr="$2"
case "$expr" in
  *"set('desktop', true)"*) d=true ;;
  *"set('desktop', false)"*) d=false ;;
  *"set('window', true)"*) w=true ;;
  *"set('window', false)"*) w=false ;;
  *"toggle('desktop')"*) if [ "$d" = true ]; then d=false; else d=true; fi ;;
  *"toggle('window')"*) if [ "$w" = true ]; then w=false; else w=true; fi ;;
esac
printf 'desktop=%s\nwindow=%s\n' "$d" "$w" > "$f"
exit 0
"""


class ToggleInvertIntegrationCase(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="invert-int-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.state = self.tmp / "state"
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.log = self.tmp / "hyprctl.log"
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        stub = self.bin / "hyprctl"
        stub.write_text(MODULE_STUB)
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def run_cli(self, *args):
        env = dict(os.environ)
        env["HOME"] = str(self.home)
        env["XDG_STATE_HOME"] = str(self.state)
        env["PATH"] = f"{self.bin}:{env['PATH']}"
        env["HYPRCTL_LOG"] = str(self.log)
        return subprocess.run(["bash", str(CLI), *args], env=env, cwd=str(REPO),
                              capture_output=True, text=True)

    def status(self, mode):
        proc = self.run_cli(mode, "--status")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_desktop_on_then_off_round_trips(self):
        self.assertEqual(self.run_cli("desktop", "on").returncode, 0)
        self.assertTrue(self.status("desktop")["enabled"])
        self.assertIn("require('Maximilian-Maag.invert').set('desktop', true)", self.calls())
        self.assertEqual(self.run_cli("desktop", "off").returncode, 0)
        self.assertFalse(self.status("desktop")["enabled"])

    def test_window_mode_is_independent_of_desktop_mode(self):
        self.run_cli("window", "on")
        self.assertTrue(self.status("window")["enabled"])
        self.assertFalse(self.status("desktop")["enabled"],
                         "pinning a window must not enable desktop inversion")

    def test_repeated_window_toggle_flips_the_pin(self):
        self.run_cli("window", "on")
        self.assertTrue(self.status("window")["enabled"])
        self.run_cli("window")            # default action: toggle
        self.assertFalse(self.status("window")["enabled"])
        self.run_cli("window")
        self.assertTrue(self.status("window")["enabled"])

    def test_both_modes_can_be_tracked_at_once(self):
        self.run_cli("desktop", "on")
        self.run_cli("window", "on")
        self.assertTrue(self.status("desktop")["enabled"])
        self.assertTrue(self.status("window")["enabled"])
        self.run_cli("desktop", "off")
        self.assertFalse(self.status("desktop")["enabled"])
        self.assertTrue(self.status("window")["enabled"])


if __name__ == "__main__":
    unittest.main()