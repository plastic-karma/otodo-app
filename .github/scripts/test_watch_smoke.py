import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import watch_smoke


class WatchBootTests(unittest.TestCase):
    def test_zero_exit_failed_migration_cannot_authorize_companion_verification(self):
        failed_boot = "[2026-09-08 08:47:39 +0000] Status=3, isTerminal=YES, Elapsed=03:29.\n\tData Migration Failed\n"
        successful_boot = "Status=4294967295, isTerminal=YES\n\tFinished\n"

        def simulator_command(*arguments, stage, **options):
            if stage.startswith("boot-phone"):
                return failed_boot
            if stage == "boot-watch":
                return successful_boot
            return ""

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "devices.json").write_text(json.dumps({"phone": "phone", "watch": "watch"}))
            with patch.object(watch_smoke, "run", side_effect=simulator_command) as command:
                with self.assertRaises(RuntimeError):
                    watch_smoke.boot_pair(output)
                stages = [call.kwargs["stage"] for call in command.call_args_list]
                self.assertEqual(stages, ["boot-phone", "restart-phone", "boot-phone-retry"])

    def test_migration_retry_requires_a_successful_second_boot_before_watch_boot(self):
        calls = []

        def simulator_command(*arguments, stage, **options):
            calls.append(stage)
            return "Data Migration Failed\n" if stage == "boot-phone" else "Finished\n"

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            watch_smoke.save_json(output / "devices.json", {"phone": "phone", "watch": "watch"})
            with patch.object(watch_smoke, "run", side_effect=simulator_command):
                watch_smoke.boot_pair(output)
            self.assertEqual(calls, ["boot-phone", "restart-phone", "boot-phone-retry", "boot-watch"])
            events = [json.loads(line) for line in (output / "progress.jsonl").read_text().splitlines()]
            self.assertEqual([event["attempt"] for event in events if event["stage"] == "phone-booted"], [2])

    def test_unknown_terminal_boot_status_is_not_retried_or_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            watch_smoke.save_json(output / "devices.json", {"phone": "phone", "watch": "watch"})
            with patch.object(watch_smoke, "run", return_value="Unexpected terminal status\n") as command:
                with self.assertRaises(RuntimeError):
                    watch_smoke.boot_pair(output)
                command.assert_called_once()

    def test_build_needs_no_device_and_cannot_boot_a_pair_during_compilation(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            with patch.object(watch_smoke, "run", return_value="") as command:
                watch_smoke.build(output, output / "DerivedData")
            self.assertTrue(command.call_args_list)
            self.assertTrue(all(call.args[0] == "xcodebuild" for call in command.call_args_list))
            self.assertIn("generic/platform=iOS Simulator", command.call_args_list[-1].args)


class WatchPairTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name)
        self.pair_id = "AB6330D0-D865-4F82-AC9B-8836F8DEAA0A"
        watch_smoke.save_json(self.output / "devices.json", {"phone": "PHONE", "watch": "WATCH"})
        watch_smoke.save_json(self.output / "pair.json", {"id": self.pair_id.lower()})
        self.pair = {"phone": {"udid": "phone"}, "watch": {"udid": "watch"},
                     "state": "(active, disconnected)"}

    def verify(self, pair):
        with patch.object(watch_smoke, "simulator_state", return_value={"pairs": {self.pair_id: pair}}):
            watch_smoke.verify_pair(self.output)

    def test_active_pair_can_be_disconnected_before_boot(self):
        self.verify(self.pair)

    def test_already_active_pair_needs_no_activation_command(self):
        with patch.object(watch_smoke, "simulator_state", return_value={"pairs": {self.pair_id: self.pair}}), \
                patch.object(watch_smoke, "run") as command:
            watch_smoke.verify_pair(self.output, activate=True)
            command.assert_not_called()

    def test_activation_requires_observed_active_state_after_the_command(self):
        inactive = {"pairs": {self.pair_id: {**self.pair, "state": "(inactive, disconnected)"}}}
        active = {"pairs": {self.pair_id: self.pair}}
        for after, success in ((active, True), (inactive, False)):
            with self.subTest(success=success), \
                    patch.object(watch_smoke, "simulator_state", side_effect=[inactive, after]), \
                    patch.object(watch_smoke, "run", return_value="") as command:
                if success:
                    watch_smoke.verify_pair(self.output, activate=True)
                else:
                    with self.assertRaises(RuntimeError):
                        watch_smoke.verify_pair(self.output, activate=True)
                command.assert_called_once_with("xcrun", "simctl", "pair_activate", self.pair_id.lower(),
                                                stage="activate-pair")

    def test_inactive_or_other_devices_cannot_authorize_verification(self):
        for change in ({"state": "(inactive, disconnected)"}, {"watch": {"udid": "stale-watch"}},
                       {"phone": {"udid": "runner-image-phone"}}):
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                self.verify({**self.pair, **change})

    def test_missing_pair_cannot_authorize_verification(self):
        with patch.object(watch_smoke, "simulator_state", return_value={"pairs": {}}):
            with self.assertRaises(RuntimeError):
                watch_smoke.verify_pair(self.output)
