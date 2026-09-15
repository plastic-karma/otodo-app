from pathlib import Path
import tempfile
import unittest

from xtool_build import protocol_array, source_membership


class SourceMembershipTests(unittest.TestCase):
    def write(self, root, relative, content="// source\n"):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def test_watch_does_not_inherit_ios_shared_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "OTodoWatch/App.swift")
            shared = [self.write(root, "OTodoShared/SharedWorkspaceStorage.swift"),
                      self.write(root, "OTodoShared/WatchSnapshotStorage.swift")]
            self.write(root, "OTodoShared/IPhoneOnly.swift")
            definition = {"sources": [{"path": "OTodoWatch"},
                                      *[{"path": str(path.relative_to(root))} for path in shared]]}
            sources, _ = source_membership(root, "OTodoWatch", definition)
            self.assertEqual(set(sources), {root / "OTodoWatch/App.swift", *shared})
            definition["sources"] = [{"path": "OTodoWatch"}, {"path": "OTodoShared"}]
            with self.assertRaises(ValueError):
                source_membership(root, "OTodoWatch", definition)

    def test_missing_required_watch_shared_member_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(root, "OTodoWatchWidget/Widget.swift")
            self.write(root, "OTodoShared/SharedWorkspaceStorage.swift")
            definition = {"sources": [{"path": "OTodoWatchWidget"},
                                      {"path": "OTodoShared/SharedWorkspaceStorage.swift"}]}
            with self.assertRaises(ValueError):
                source_membership(root, "OTodoWatchWidget", definition)

    def test_excluded_source_directory_and_explicit_resource_membership(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.write(root, "Share/Controller.swift")
            self.write(root, "Share/DebugOnly/Debug.swift")
            resource = self.write(root, "Share/ShareSource.js", "function run() {}\n")
            self.write(root, "Share/Info.plist")
            definition = {"sources": [{"path": "Share", "excludes": ["DebugOnly", "ShareSource.js"]},
                                      {"path": "Share/ShareSource.js", "buildPhase": "resources"}]}
            sources, resources = source_membership(root, "OTodoShareExtension", definition)
            self.assertEqual(sources, [source])
            self.assertEqual(resources, [resource])


class ProtocolInputTests(unittest.TestCase):
    def test_toolchain_catalog_cannot_be_passed_as_compiler_protocol_array(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "protocols.json"
            path.write_text('{"version": 1, "constValueProtocols": ["AppIntent"]}')
            with self.assertRaises(ValueError):
                protocol_array(path)
            path.write_text('["AppIntent", "AppShortcutsProvider"]')
            self.assertEqual(protocol_array(path), ["AppIntent", "AppShortcutsProvider"])


if __name__ == "__main__":
    unittest.main()
