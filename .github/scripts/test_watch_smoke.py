import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import watch_smoke


class WatchBootTests(unittest.TestCase):
    def test_zero_exit_failed_migration_cannot_authorize_a_companion_build(self):
        failed_boot = "[2026-09-08 08:47:39 +0000] Status=3, isTerminal=YES, Elapsed=03:29.\n\tData Migration Failed\n"
        successful_boot = "Status=4294967295, isTerminal=YES\n\tFinished\n"

        def simulator_command(*arguments, stage, **options):
            if stage == "boot-phone":
                return failed_boot
            if stage == "boot-watch":
                return successful_boot
            return ""

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "devices.json").write_text(json.dumps({"phone": "phone", "watch": "watch"}))
            with patch.object(watch_smoke, "run", side_effect=simulator_command):
                with self.assertRaises(RuntimeError):
                    watch_smoke.build(output, output / "DerivedData")
