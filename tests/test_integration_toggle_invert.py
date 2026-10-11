"""Integration tests: bin/omarchy-toggle-invert round-tripping through Hyprland.

A stub hyprctl emulates the Lua module — it parses the dispatched expression and
rewrites the status file the CLI later reads back — so the full command -> module
-> state -> `--status` path is exercised. The user's real session is never used.

Window scope is modelled as a single value: the effect of the "focused" window,
which is exactly what the module reports while one window has focus.
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
# Emulates hypr/invert.lua: applies the dispatched set()/cycle() to the status file.
# Status lines hold an effect name (off|invert|contrast), not a boolean.
echo "$*" >> "$HYPRCTL_LOG"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
mkdir -p "$STATE_DIR"
f="$STATE_DIR/invert.status"
[ -f "$f" ] || printf 'desktop=off\nwindow=off\n' > "$f"
d=$(sed -n 's/^desktop=//p' "$f"); [ -n "$d" ] || d=off
w=$(sed -n 's/^window=//p'  "$f"); [ -n "$w" ] || w=off
case "$d" in true) d=invert;; false) d=off;; esac
case "$w" in true) w=invert;; false) w=off;; esac
expr="$2"
case "$expr" in
  *"set('desktop', 'invert')"*)   d=invert ;;
  *"set('desktop', 'contrast')"*) d=contrast ;;
  *"set('desktop', 'off')"*)      d=off ;;
  *"set('window', 'invert')"*)    w=invert ;;
  *"set('window', 'contrast')"*)  w=contrast ;;
  *"set('window', 'off')"*)       w=off ;;
  *"cycle('desktop')"*) case "$d" in off) d=invert;; invert) d=contrast;; *) d=off;; esac ;;
  *"cycle('window')"*)  case "$w" in off) w=invert;; invert) w=contrast;; *) w=off;; esac ;;
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

    def status(self, scope):
        proc = self.run_cli(scope, "--status")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""

    def test_desktop_on_off_round_trips(self):
        self.assertEqual(self.run_cli("desktop", "on").returncode, 0)
        self.assertEqual(self.status("desktop"), {"mode": "desktop", "effect": "invert",
                                                  "enabled": True})
        self.assertIn("require('Maximilian-Maag.invert').set('desktop', 'invert')",
                      self.calls())
        self.assertEqual(self.run_cli("desktop", "off").returncode, 0)
        self.assertEqual(self.status("desktop")["effect"], "off")

    def test_desktop_cycle_walks_off_invert_contrast(self):
        self.run_cli("desktop", "toggle")
        self.assertEqual(self.status("desktop")["effect"], "invert")
        self.run_cli("desktop", "toggle")
        self.assertEqual(self.status("desktop")["effect"], "contrast")
        self.run_cli("desktop", "toggle")
        self.assertEqual(self.status("desktop")["effect"], "off")

    def test_window_mode_is_independent_of_desktop_mode(self):
        self.run_cli("window", "contrast")
        self.assertEqual(self.status("window")["effect"], "contrast")
        self.assertEqual(self.status("desktop")["effect"], "off",
                         "changing a window must not change the desktop effect")

    def test_repeated_window_cycle_walks_off_invert_contrast(self):
        self.run_cli("window")            # default action: cycle
        self.assertEqual(self.status("window")["effect"], "invert")
        self.run_cli("window")
        self.assertEqual(self.status("window")["effect"], "contrast")
        self.run_cli("window")
        self.assertEqual(self.status("window")["effect"], "off")

    def test_both_scopes_can_be_tracked_at_once(self):
        self.run_cli("desktop", "invert")
        self.run_cli("window", "contrast")
        self.assertEqual(self.status("desktop")["effect"], "invert")
        self.assertEqual(self.status("window")["effect"], "contrast")
        self.run_cli("desktop", "off")
        self.assertEqual(self.status("desktop")["effect"], "off")
        self.assertEqual(self.status("window")["effect"], "contrast")


if __name__ == "__main__":
    unittest.main()
