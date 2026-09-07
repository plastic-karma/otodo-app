from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch

import validate_bundles as bundles


def simulator_binary(group, cpu=0x0100000C):
    entitlements = plistlib.dumps({"com.apple.security.application-groups": [group]})
    command_size = 72 + 80
    content_offset = 32 + command_size
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, cpu, 0, 2, 1, command_size, 0, 0)
    segment = struct.pack(
        "<II16sQQQQiiII", 0x19, command_size, b"__TEXT", 0, content_offset + len(entitlements),
        0, content_offset + len(entitlements), 7, 5, 1, 0,
    )
    section = struct.pack(
        "<16s16sQQIIIIIIII", b"__entitlements", b"__TEXT", 0, len(entitlements),
        content_offset, 0, 0, 0, 0, 0, 0, 0,
    )
    return header + segment + section + entitlements


def universal_simulator_binary(first_group, second_group):
    first = simulator_binary(first_group)
    second = simulator_binary(second_group, 0x01000007)
    offset = 8 + 2 * 20
    return (
        struct.pack(">II", 0xCAFEBABE, 2)
        + struct.pack(">IIIII", 0x0100000C, 0, offset, len(first), 0)
        + struct.pack(">IIIII", 0x01000007, 0, offset + len(first), len(second), 0)
        + first + second
    )


class BuiltBundleTests(unittest.TestCase):
    def make_app(self, root, platform="archive"):
        app = root / "OTodo.app"
        project = bundles.load_project(Path(__file__).resolve().parents[2])
        for target, identifier, relative, _, _ in bundles.COMPONENTS:
            bundle = app / relative
            bundle.mkdir(parents=True, exist_ok=True)
            info = dict(project["targets"][target]["info"]["properties"])
            info.update({
                "CFBundleIdentifier": identifier,
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "1234567890",
                "CFBundleExecutable": target,
                "DTPlatformName": (
                    ("watchsimulator" if target.startswith("OTodoWatch") else "iphonesimulator")
                    if platform == "simulator" else ("watchos" if target.startswith("OTodoWatch") else "iphoneos")
                ),
            })
            if target == "OTodo":
                info["UIDeviceFamily"] = [1, 2]
            (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
            binary = bundle / target
            binary.write_bytes(simulator_binary(bundles.APP_GROUP) if platform == "simulator" else b"test executable")
            binary.chmod(0o755)
        return app

    def signed_groups(self, arguments, **kwargs):
        if "--entitlements" in arguments:
            return plistlib.dumps({"com.apple.security.application-groups": ["group.plastickarma.otodo"]}).decode()
        return ""

    def test_wrong_effective_share_group_fails_even_when_source_declaration_is_correct(self):
        def codesign(arguments, **kwargs):
            if "--entitlements" in arguments and arguments[-1].endswith("OTodoShareExtension.appex"):
                return plistlib.dumps({"com.apple.security.application-groups": ["group.other"]}).decode()
            return self.signed_groups(arguments, **kwargs)

        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            with patch.object(bundles, "run_command", side_effect=codesign):
                with self.assertRaisesRegex(ValueError, "OTodoShareExtension.*effective App Groups"):
                    bundles.validate_built(app, "archive", "1.2.3", "1234567890")

    def test_missing_embedded_complication_executable_cannot_pass_metadata_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            (app / "Watch/OTodoWatch.app/PlugIns/OTodoWatchWidget.appex/OTodoWatchWidget").unlink()
            with patch.object(bundles, "run_command", side_effect=self.signed_groups):
                with self.assertRaisesRegex(ValueError, "OTodoWatchWidget.*missing, empty, or non-executable"):
                    bundles.validate_built(app, "archive")

    def test_mismatched_complication_build_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory))
            path = app / "Watch/OTodoWatch.app/PlugIns/OTodoWatchWidget.appex/Info.plist"
            info = plistlib.loads(path.read_bytes())
            info["CFBundleVersion"] = "1234567889"
            path.write_bytes(plistlib.dumps(info))
            with patch.object(bundles, "run_command", side_effect=self.signed_groups):
                with self.assertRaisesRegex(ValueError, "OTodoWatchWidget.*CFBundleVersion"):
                    bundles.validate_built(app, "archive")

    def test_simulator_uses_linked_permissions_even_when_codesign_entitlements_are_empty(self):
        def simulator_codesign(arguments, **kwargs):
            return plistlib.dumps({}).decode() if "--entitlements" in arguments else ""

        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(Path(directory), "simulator")
            watch = app / "Watch/OTodoWatch.app/OTodoWatch"
            watch.write_bytes(universal_simulator_binary(bundles.APP_GROUP, bundles.APP_GROUP))
            with patch.object(bundles, "run_command", side_effect=simulator_codesign):
                bundles.validate_built(app, "simulator")
                watch.write_bytes(universal_simulator_binary(bundles.APP_GROUP, "group.other"))
                with self.assertRaises(ValueError) as error:
                    bundles.validate_built(app, "simulator")
                self.assertIn("OTodoWatch", str(error.exception))

    def test_missing_or_truncated_simulator_sections_cannot_fall_back_to_source_groups(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "OTodo"
            valid = simulator_binary(bundles.APP_GROUP)
            binary.write_bytes(valid.replace(b"__entitlements".ljust(16, b"\0"), b"__other".ljust(16, b"\0")))
            with self.assertRaises(ValueError):
                bundles.simulated_entitlements(binary)
            binary.write_bytes(valid[:-20])
            with self.assertRaises(ValueError):
                bundles.simulated_entitlements(binary)


if __name__ == "__main__":
    unittest.main()
