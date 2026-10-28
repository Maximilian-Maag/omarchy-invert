"""Guard the mutation runner's equivalent-mutant filter.

`tools/mutator.py` records each survivor's operator under the key `"operator"` but its
equivalent-mutant filter once looked up `"kind"` — a key that never exists — so every
declared equivalent mutant silently stayed in the denominator (issue #1). These tests
drive the REAL runner over a throwaway repo fixture and assert the filter actually
excludes a declared mutant, so the same key mismatch cannot come back unnoticed.
"""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parent.parent
MUTATOR = REPO / "tools" / "mutator.py"


class MutatorEquivalentCase(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="inv-mutator-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        (self.tmp / "tools").mkdir(parents=True)
        shutil.copy2(MUTATOR, self.tmp / "tools" / "mutator.py")
        # A two-mutant python target: `True -> False` (the test notices) and `1 -> 2`
        # (the test does NOT, so it survives) — declared equivalent. Without the filter
        # the survivor counts and the rate is 1/2; with it the survivor is excluded -> 1/1.
        (self.tmp / "target.py").write_text("FLAG = True\nLIMIT = 1\n")
        checker = self.tmp / "check.sh"
        checker.write_text(
            "#!/bin/bash\n"
            "grep -q 'FLAG = True' target.py\n")
        checker.chmod(0o755)
        (self.tmp / "tests").mkdir()
        (self.tmp / "tests" / "mutation.json").write_text(json.dumps({
            "min_kill_rate": 0.85,
            "targets": [{
                "path": "target.py",
                "lang": "python",
                "tests": ["bash", "check.sh"],
                "equivalent": [
                    {"line": 2, "kind": "number\u00b11",
                     "reason": "test fixture: declared so the FILTER can be observed"},
                ],
            }],
        }))

    def run_mutator(self):
        report = self.tmp / "report.json"
        proc = subprocess.run(
            [sys.executable, str(self.tmp / "tools" / "mutator.py"),
             "--config", "tests/mutation.json", "--json", str(report)],
            cwd=str(self.tmp), capture_output=True, text=True)
        return proc, json.loads(report.read_text())

    def test_a_declared_equivalent_mutant_is_excluded_from_the_score(self):
        proc, report = self.run_mutator()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(report[0]["equivalent"], 1,
                         "the declared equivalent mutant was not excluded")
        self.assertEqual(report[0]["counted"], 1)
        self.assertEqual(report[0]["kill_rate"], 1.0)

    def test_the_filter_matches_on_the_operator_key(self):
        proc, report = self.run_mutator()
        survived = [m for m in report[0]["mutants"] if m["verdict"] == "survived"]
        self.assertTrue(survived, "fixture should produce a survivor to exercise the filter")
        for m in survived:
            self.assertIn("operator", m)


if __name__ == "__main__":
    unittest.main()
