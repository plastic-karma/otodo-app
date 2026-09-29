import json
from pathlib import Path
import tempfile
import unittest

import ios_tests


class CoverageTests(unittest.TestCase):
    def test_inventory_retains_disabled_tests_and_rejects_missing_or_duplicate_coverage(self):
        document = {"errors": [], "values": [{"enabledTests": [
            {"identifier": "OTodoAppTests/OTodoAppTests.CaptureIntentTests/testCapture()"},
            {"identifier": "OTodoUITests/OTodoUITests/testAddAndEditTodo()"},
        ], "disabledTests": [{"identifier": "OTodoUITests/OTodoUITests/testUnavailable()"}]}]}
        tests, disabled = ios_tests.enumerated_tests(document)
        self.assertEqual(tests, ["OTodoAppTests/CaptureIntentTests/testCapture",
                                 "OTodoUITests/OTodoUITests/testAddAndEditTodo"])
        self.assertEqual(disabled, ["OTodoUITests/OTodoUITests/testUnavailable()"])
        for invalid in ({"errors": ["test bundle could not load"], "values": document["values"]},
                        {"errors": [], "values": []},
                        {"errors": [], "values": document["values"] * 2}):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                ios_tests.enumerated_tests(invalid)

    def test_missing_failed_skipped_or_foreign_tests_cannot_pass_local_verification(self):
        expected = ["OTodoAppTests/HostedTests/testSharedContainer", "OTodoUITests/EditorTests/testCapture"]
        passed = [{"identifier": test, "status": "passed"} for test in expected]
        cases = [passed[:1], [passed[0], {**passed[1], "status": "skipped"}],
                 [{**passed[0], "status": "failed"}, *passed],
                 [*passed, {"identifier": "ForeignTests/Other/testOther", "status": "passed"}]]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = root / "command-tests.json"
            for observed in cases:
                record.write_text(json.dumps({"stage": "ios-tests", "test_cases": observed}))
                with self.subTest(observed=observed), self.assertRaises(ValueError):
                    ios_tests.verify_coverage(root, expected)
            record.write_text(json.dumps({"stage": "ios-tests", "test_cases": passed}))
            ios_tests.verify_coverage(root, expected)
            self.assertEqual(json.loads((root / "coverage.json").read_text())["observed"],
                             dict.fromkeys(expected, "passed"))


if __name__ == "__main__":
    unittest.main()
