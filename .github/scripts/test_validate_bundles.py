from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import validate_bundles as bundles


class BuiltBundleTests(unittest.TestCase):
    def make_app(self, root):
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
                "DTPlatformName": "watchos" if target.startswith("OTodoWatch") else "iphoneos",
            })
            if target == "OTodo":
                info["UIDeviceFamily"] = [1, 2]
            (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
            binary = bundle / target
            binary.write_bytes(b"test executable")
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


if __name__ == "__main__":
    unittest.main()
