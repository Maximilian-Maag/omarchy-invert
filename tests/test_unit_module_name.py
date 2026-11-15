"""Unit tests: the Lua module is required by exactly one, resolvable name.

Three places name the module and must agree:

  * manifest.json      omarchy_meta.hyprland.require  (the declared name)
  * install.sh         the require(...) line it wires into hyprland.lua
  * bin/omarchy-toggle-invert  the require(...) it dispatches via hyprctl

If they drift, the shortcut and the CLI call a module that was never installed
(a manifest declaring "omarchy.invert" while the installer writes
"Maximilian-Maag.invert" resolves nothing). This test pins them together.
"""
import json
import pathlib
import re
import unittest

REPO = pathlib.Path(__file__).resolve().parent.parent

# Match require("name"), require('name') and the backslash-escaped form inside a
# bash double-quoted string (require(\"name\")).
REQUIRE = re.compile(r"require\(\s*\\?['\"]([A-Za-z0-9_.-]+)\\?['\"]\s*\)")


class ModuleRequireNameCase(unittest.TestCase):
    def test_declared_require_name_matches_the_installed_one(self):
        manifest = json.loads((REPO / "manifest.json").read_text())
        declared = manifest["omarchy_meta"]["hyprland"]["require"]

        install = (REPO / "install.sh").read_text()
        installed = set(REQUIRE.findall(install))
        self.assertEqual(
            installed, {declared},
            "install.sh must wire exactly the declared module name "
            f"{declared!r}; it wires {sorted(installed)}")

        cli = (REPO / "bin/omarchy-toggle-invert").read_text()
        dispatched = set(REQUIRE.findall(cli))
        self.assertEqual(
            dispatched, {declared},
            "the CLI must dispatch exactly the declared module name "
            f"{declared!r}; it dispatches {sorted(dispatched)}")

    def test_declared_name_is_not_in_the_reserved_omarchy_namespace(self):
        manifest = json.loads((REPO / "manifest.json").read_text())
        declared = manifest["omarchy_meta"]["hyprland"]["require"]
        self.assertFalse(declared.startswith("omarchy."),
                         "the omarchy.* module namespace is reserved")


if __name__ == "__main__":
    unittest.main()
