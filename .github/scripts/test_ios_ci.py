#!/usr/bin/env python3
"""Regressions for full coverage, diagnosis isolation, and failed rerun evidence."""

from collections import Counter
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import ios_ci


class CoverageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        environment = patch.dict(os.environ, {
            "CI_MODE": "full", "CI_FILTER": "", "GITHUB_SHA": "a" * 40,
            "GITHUB_RUN_ID": "123", "GITHUB_STEP_SUMMARY": "",
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.tests = sorted(ios_ci.CRITICAL_TESTS | ios_ci.SYSTEM_TESTS | {
            "OTodoAppTests/HostedTests/testSharedContainer",
            "OTodoUITests/OTodoUITests/testNewBehavior",
            "OTodoUITests/OtherTests/testNewScene",
        })
        self.groups = ios_ci.make_plan(self.tests, [], {}, mode="full", test_filter="")
        self.needs = {job: {"result": "success"} for job in ios_ci.REQUIRED_JOBS}
        self.manifest = {
            "schema_version": 1, "sha": "a" * 40, "run_id": "123", "mode": "full", "filter": "",
            "plan_id": "compiled-plan", "xctestrun": "OTodo.xctestrun",
            "groups": self.groups, "expected": self.tests,
        }

    def evidence(self, group, *, attempt=1, missing=False):
        directory = self.directory / f"{group}-{attempt}"
        expected = self.groups[group]
        observed = {test: "passed" for test in expected}
        if missing:
            del observed[expected[-1]]
        coverage = {
            "schema_version": 1, "sha": "a" * 40, "run_id": "123", "attempt": attempt,
            "mode": "full", "filter": "", "plan_id": "compiled-plan", "group": group,
            "expected": expected, "observed": observed,
            "missing": [expected[-1]] if missing else [], "unexpected": [], "unsuccessful": [],
            "command_status": 124 if missing else 0,
        }
        ios_ci.write_json(directory / f"coverage-{group}.json", coverage)
        ios_ci.write_json(directory / "manifest.json", self.manifest)
        return directory

    def complete_evidence(self):
        for group in ios_ci.GROUPS:
            self.evidence(group)

    def test_compiled_discovery_preserves_new_tests_once_and_groups_system_interactions(self):
        document = {"errors": [], "values": [{
            "enabledTests": [{"identifier": test + "()"} for test in self.tests], "disabledTests": [],
        }]}
        tests, disabled = ios_ci.enumerated_tests(document)
        groups = ios_ci.make_plan(tests, disabled, {}, mode="full", test_filter="")
        self.assertEqual(Counter(test for group in groups.values() for test in group), Counter(self.tests))
        self.assertTrue(ios_ci.SYSTEM_TESTS.issubset(groups["integration"]))
        self.assertIn("OTodoAppTests/HostedTests/testSharedContainer", groups["smoke"])
        self.assertNotIn("OTodoUITests/OTodoUITests/testNewBehavior", groups["smoke"])
        with self.assertRaises(ValueError):
            ios_ci.enumerated_tests({"errors": ["test bundle could not load"], "values": document["values"]})
        with self.assertRaises(ValueError):
            ios_ci.enumerated_tests({"errors": [], "values": []})

    def test_focused_success_cannot_be_used_as_full_verification(self):
        focused = ios_ci.make_plan(self.tests, [], {}, mode="focused", test_filter="OTodoUITests/OtherTests")
        self.assertEqual(focused["smoke"], ["OTodoUITests/OtherTests/testNewScene"])
        self.complete_evidence()
        self.assertEqual(ios_ci.verify_evidence(self.directory, self.needs), len(self.tests))
        with patch.dict(os.environ, {"CI_MODE": "focused", "CI_FILTER": "OTodoUITests/OtherTests"}):
            with self.assertRaises(ValueError):
                ios_ci.verify_evidence(self.directory, self.needs)
        with self.assertRaises(ValueError):
            ios_ci.make_plan(self.tests, [], {}, mode="focused", test_filter="OTodoUITests/MissingTests")
        with self.assertRaises(ValueError):
            ios_ci.make_plan(self.tests, [], {}, mode="full", test_filter="OTodoUITests/OtherTests")

    def test_partial_platform_or_observed_test_coverage_cannot_pass(self):
        self.complete_evidence()
        self.assertEqual(ios_ci.verify_evidence(self.directory, self.needs), len(self.tests))
        self.needs["watchos-simulator"]["result"] = "cancelled"
        with self.assertRaises(ValueError) as error:
            ios_ci.verify_evidence(self.directory, self.needs)
        self.assertIn("watchos-simulator", str(error.exception))
        self.needs["watchos-simulator"]["result"] = "success"
        self.evidence("functional", missing=True)
        with self.assertRaises(ValueError):
            ios_ci.verify_evidence(self.directory, self.needs)

    def test_newer_failed_attempt_cannot_reuse_older_passing_evidence(self):
        self.complete_evidence()
        self.assertEqual(ios_ci.verify_evidence(self.directory, self.needs), len(self.tests))
        self.evidence("functional", attempt=2, missing=True)
        with self.assertRaises(ValueError) as error:
            ios_ci.verify_evidence(self.directory, self.needs)
        self.assertIn("functional", str(error.exception))
        self.evidence("functional", attempt=3)
        self.assertEqual(ios_ci.verify_evidence(self.directory, self.needs), len(self.tests))
        with patch.dict(os.environ, {"GITHUB_SHA": "b" * 40}):
            with self.assertRaises(ValueError):
                ios_ci.verify_evidence(self.directory, self.needs)

    def test_product_transport_keeps_executables_and_rejects_escaping_links(self):
        archive = self.directory / "products.tar.gz"
        script = b"#!/bin/sh\nprintf 'executable survived transport'\n"
        with tarfile.open(archive, "w:gz") as output:
            executable = tarfile.TarInfo("Products/App.app/App")
            executable.mode = 0o755
            executable.size = len(script)
            output.addfile(executable, io.BytesIO(script))
            link = tarfile.TarInfo("Products/Current")
            link.type = tarfile.SYMTYPE
            link.linkname = "App.app"
            output.addfile(link)
        restored = self.directory / "restored"
        ios_ci.unpack_products(archive, restored)
        execution = subprocess.run(
            [str(restored / "Products/Current/App")], capture_output=True, text=True, check=True,
        )
        self.assertEqual(execution.stdout, "executable survived transport")
        with tarfile.open(archive, "w:gz") as output:
            link = tarfile.TarInfo("Products/escape")
            link.type = tarfile.SYMTYPE
            link.linkname = "../../outside"
            output.addfile(link)
        with self.assertRaises(tarfile.FilterError):
            ios_ci.unpack_products(archive, self.directory / "rejected")
        self.assertFalse((self.directory / "outside").exists())


if __name__ == "__main__":
    unittest.main()
