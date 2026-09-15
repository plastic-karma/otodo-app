from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

import xtool_archive as archive


def thin(arch, *, payload=b"machine-code-and-data", signature=b"unsigned", symbols=b"symbol-table", flags=0):
    """Small executable with real 32/64-bit segment layouts and mutable LINKEDIT."""
    wide = arch == "arm64"
    cpu = 0x0100000C if wide else 0x0200000C
    header_size = 32 if wide else 28
    segment_size, section_size = (72, 80) if wide else (56, 68)
    text_command_size = segment_size + section_size
    command_bytes = text_command_size + segment_size + 16 + 24 + 24
    content_offset = header_size + command_bytes
    linkedit_offset = content_offset + len(payload)
    linkedit = symbols + signature
    header = struct.pack("<7I", 0xFEEDFACF if wide else 0xFEEDFACE, cpu, 0, 2, 5, command_bytes, flags)
    if wide:
        header += struct.pack("<I", 0)
    segment_format = "<II16sQQQQiiII" if wide else "<II16sIIIIiiII"
    text = struct.pack(segment_format, 0x19 if wide else 1, text_command_size, b"__TEXT",
                       0, linkedit_offset, 0, linkedit_offset, 7, 5, 1, 0)
    section_format = "<16s16sQQ8I" if wide else "<16s16s9I"
    section_fields = [content_offset, len(payload), content_offset, 0, 0, 0, 0x80000400, 0, 0]
    if wide:
        section_fields.append(0)
    text += struct.pack(section_format, b"__text", b"__TEXT", *section_fields)
    links = struct.pack(segment_format, 0x19 if wide else 1, segment_size, b"__LINKEDIT",
                        linkedit_offset, len(linkedit), linkedit_offset, len(linkedit), 7, 1, 0, 0)
    signing = struct.pack("<4I", 0x1D, 16, linkedit_offset + len(symbols), len(signature))
    uuid = struct.pack("<2I", 0x1B, 24) + bytes([1 if wide else 2]) * 16
    platform = struct.pack("<6I", 0x32, 24, 4, (26 if wide else 10) << 16, (26 << 16) | (5 << 8), 0)
    return header + text + links + signing + uuid + platform + payload + linkedit


def fat(slices, *, wide=False):
    entry_size = 32 if wide else 20
    offset = 8 + entry_size * len(slices)
    table = struct.pack(">2I", 0xCAFEBABF if wide else 0xCAFEBABE, len(slices))
    contents = b""
    for arch, binary in slices:
        cpu = 0x0100000C if arch == "arm64" else 0x0200000C
        if wide:
            table += struct.pack(">2I2Q2I", cpu, 0, offset, len(binary), 0, 0)
        else:
            table += struct.pack(">5I", cpu, 0, offset, len(binary), 0)
        offset += len(binary)
        contents += binary
    return table + contents


class MachOIdentityTests(unittest.TestCase):
    def fingerprints(self, directory, filename, contents):
        path = Path(directory) / filename
        path.write_bytes(contents)
        return archive.macho_fingerprints(path)

    def test_distribution_resigning_and_symbol_stripping_preserve_both_watch_slices(self):
        with tempfile.TemporaryDirectory() as directory:
            original = self.fingerprints(directory, "compiled", fat([
                ("arm64", thin("arm64")), ("arm64_32", thin("arm64_32")),
            ]))
            exported = self.fingerprints(directory, "exported", fat([
                ("arm64_32", thin("arm64_32", signature=b"Apple-distribution-signature" * 8, symbols=b"", flags=0x04000000)),
                ("arm64", thin("arm64", signature=b"other-signature", symbols=b"", flags=0x04000000)),
            ], wide=True))
            self.assertEqual(set(original), {"arm64", "arm64_32"})
            self.assertEqual(original, exported)

    def test_one_tampered_watch_slice_cannot_match_compiled_products(self):
        with tempfile.TemporaryDirectory() as directory:
            original = self.fingerprints(directory, "compiled", fat([
                ("arm64", thin("arm64")), ("arm64_32", thin("arm64_32")),
            ]))
            tampered = self.fingerprints(directory, "tampered", fat([
                ("arm64", thin("arm64")), ("arm64_32", thin("arm64_32", payload=b"machine-code-and-DATA")),
            ]))
            self.assertEqual(original["arm64"], tampered["arm64"])
            self.assertNotEqual(original, tampered)

    def test_lost_watch_slice_cannot_pass_architecture_or_identity_checks(self):
        component = {"name": "OTodoWatch", "platform": "watchos", "relative_path": "Watch/OTodoWatch.app"}
        platforms = {"watchos": {"minimum_os": "10.0", "sdk_version": "26.5"}}
        with tempfile.TemporaryDirectory() as directory:
            missing = self.fingerprints(directory, "thinned", thin("arm64_32"))
            with self.assertRaises(ValueError):
                archive._check_binary(missing, component, platforms)

    def test_dual_watch_extension_preserves_architecture_specific_deployment_floors(self):
        component = {"name": "OTodoWatchWidget", "platform": "watchos", "relative_path": "PlugIns/OTodoWatchWidget.appex"}
        platforms = {"watchos": {"minimum_os": "10.0", "sdk_version": "26.5",
                                "architecture_minimum_os": {"arm64": "26.0", "arm64_32": "10.0"}}}
        with tempfile.TemporaryDirectory() as directory:
            actual = self.fingerprints(directory, "watch", fat([
                ("arm64", thin("arm64")), ("arm64_32", thin("arm64_32")),
            ]))
            archive._check_binary(actual, component, platforms)
            platforms["watchos"]["architecture_minimum_os"]["arm64_32"] = "26.0"
            with self.assertRaises(ValueError):
                archive._check_binary(actual, component, platforms)

    def test_overlapping_and_mislabeled_fat_slices_are_rejected(self):
        valid = fat([("arm64", thin("arm64")), ("arm64_32", thin("arm64_32"))])
        with tempfile.TemporaryDirectory() as directory:
            overlap = bytearray(valid)
            first_offset = struct.unpack_from(">I", overlap, 16)[0]
            struct.pack_into(">I", overlap, 36, first_offset)
            with self.assertRaises(ValueError):
                self.fingerprints(directory, "overlap", overlap)
            mislabeled = bytearray(valid)
            struct.pack_into(">I", mislabeled, 28, 0x0100000C)
            with self.assertRaises(ValueError):
                self.fingerprints(directory, "mislabeled", mislabeled)


class ExportExtractionTests(unittest.TestCase):
    def test_parent_traversal_cannot_write_outside_extraction_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "malicious.ipa"
            with zipfile.ZipFile(ipa, "w") as output:
                output.writestr("../escaped", b"untrusted payload")
            destination = root / "unpacked"
            destination.mkdir()
            with self.assertRaisesRegex(ValueError, "Unsafe IPA member"):
                archive._extract_ipa(ipa, destination)
            self.assertFalse((root / "escaped").exists())


if __name__ == "__main__":
    unittest.main()
