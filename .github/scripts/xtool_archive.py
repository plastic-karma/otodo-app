#!/usr/bin/env python3
"""Assemble xtool products with Apple resource tools; verify the exported distribution."""

import argparse
from copy import deepcopy
from datetime import datetime, timezone
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import tempfile
import zipfile

from ci_runtime import CommandError, annotate, run_command
from manage_api_certificates import required_environment
from validate_bundles import COMPONENTS, read_plist, require, validate_built, validate_groups

TEAM = "9492A97LWY"
ARCHES = {"iphoneos": {"arm64"}, "watchos": {"arm64", "arm64_32"}}
ZERO_FILL = {1, 12, 18}


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _version(value: int) -> list[int]:
    return [value >> 16, (value >> 8) & 255, value & 255]


def _version_string(value: str) -> list[int]:
    parts = [int(part) for part in value.split(".")]
    require(1 <= len(parts) <= 3, f"Invalid OS version: {value}")
    return parts + [0] * (3 - len(parts))


def _thin_fingerprint(data: bytes) -> tuple[str, dict]:
    """Hash file-backed sections, not mutable signing/symbol-table load commands.

    arm64_32 uses CPU_ARCH_ABI64_32, but its Mach-O header may be the 28-byte
    MH_MAGIC form. Header layout is selected by magic, never CPU name.
    """
    formats = {b"\xce\xfa\xed\xfe": ("<", False), b"\xcf\xfa\xed\xfe": ("<", True),
               b"\xfe\xed\xfa\xce": (">", False), b"\xfe\xed\xfa\xcf": (">", True)}
    require(data[:4] in formats, "Not a thin Mach-O binary")
    endian, wide = formats[data[:4]]
    header_size = 32 if wide else 28
    require(len(data) >= header_size, "Truncated Mach-O header")
    _, cpu, subtype, filetype, count, command_bytes, flags = struct.unpack_from(endian + "7I", data)
    require(cpu in {0x0100000C, 0x0200000C}, f"Unsupported Mach-O CPU {cpu:#x}")
    require((subtype & 0xFFFFFF) in {0, 1}, f"Unsupported ARM subtype {subtype:#x}")
    arch = "arm64" if cpu == 0x0100000C else "arm64_32"
    command_end = header_size + command_bytes
    require(command_end <= len(data) and count <= command_bytes // 8, "Truncated load commands")
    offset = header_size
    sections = []
    uuids = []
    platforms = []
    dependencies = []
    rpaths = []
    entries = []
    for _ in range(count):
        require(offset + 8 <= command_end, "Truncated Mach-O load command")
        command, size = struct.unpack_from(endian + "2I", data, offset)
        require(size >= 8 and offset + size <= command_end, "Invalid load command size")
        if command in {1, 0x19}:
            segment_wide = command == 0x19
            segment_size, section_size = (72, 80) if segment_wide else (56, 68)
            require(size >= segment_size, "Truncated segment command")
            segment = data[offset + 8:offset + 24].rstrip(b"\0").decode("ascii")
            if segment_wide:
                _, _, file_offset, file_size, _, _, section_count, _ = struct.unpack_from(endian + "4Q4I", data, offset + 24)
            else:
                _, _, file_offset, file_size, _, _, section_count, _ = struct.unpack_from(endian + "8I", data, offset + 24)
            require(segment_size + section_count * section_size == size, "Invalid segment section count")
            require(file_offset + file_size <= len(data), "Segment exceeds Mach-O slice")
            for index in range(section_count):
                position = offset + segment_size + index * section_size
                name = data[position:position + 16].rstrip(b"\0").decode("ascii")
                owner = data[position + 16:position + 32].rstrip(b"\0").decode("ascii")
                require(owner == segment, "Mismatched section segment")
                if segment_wide:
                    address, length, start, alignment, _, _, section_flags, reserved1, reserved2, reserved3 = struct.unpack_from(endian + "2Q8I", data, position + 32)
                else:
                    address, length, start, alignment, _, _, section_flags, reserved1, reserved2 = struct.unpack_from(endian + "9I", data, position + 32)
                    reserved3 = 0
                if segment == "__LINKEDIT":
                    continue
                record = {"segment": segment, "section": name, "address": address, "size": length,
                          "alignment": alignment, "flags": section_flags,
                          "reserved": [reserved1, reserved2, reserved3]}
                # These section types have virtual size but no bytes in the file.
                if section_flags & 255 not in ZERO_FILL:
                    require(start >= file_offset and start + length <= file_offset + file_size,
                            f"Section {segment},{name} exceeds its segment")
                    record["sha256"] = hashlib.sha256(data[start:start + length]).hexdigest()
                sections.append(record)
        elif command == 0x1B:
            require(size == 24, "Invalid LC_UUID")
            uuids.append(data[offset + 8:offset + 24].hex())
        elif command == 0x32:
            require(size >= 24, "Invalid LC_BUILD_VERSION")
            platform, minimum, sdk, tools = struct.unpack_from(endian + "4I", data, offset + 8)
            require(size == 24 + tools * 8, "Invalid build-version tool list")
            platforms.append({"platform": platform, "minimum": _version(minimum), "sdk": _version(sdk)})
        elif command in {0x25, 0x30}:
            require(size == 16, "Invalid minimum-version command")
            minimum, sdk = struct.unpack_from(endian + "2I", data, offset + 8)
            platforms.append({"platform": 2 if command == 0x25 else 4,
                              "minimum": _version(minimum), "sdk": _version(sdk)})
        elif command in {0xC, 0x18 | 0x80000000, 0x1F | 0x80000000, 0x20, 0x23 | 0x80000000, 0xD, 0x1C | 0x80000000}:
            require(size >= 12, "Invalid dylib/rpath command")
            start = struct.unpack_from(endian + "I", data, offset + 8)[0]
            require(12 <= start < size, "Invalid dylib/rpath string offset")
            text = data[offset + start:offset + size].split(b"\0", 1)[0].decode("utf-8")
            (rpaths if command == 0x8000001C else dependencies).append([command, text])
        elif command == 0x80000028:
            require(size == 24, "Invalid LC_MAIN")
            entries.append(list(struct.unpack_from(endian + "2Q", data, offset + 8)))
        offset += size
    require(offset == command_end, "Unaccounted Mach-O load-command bytes")
    require(sections and any(s["segment"] == "__TEXT" and s.get("sha256") for s in sections),
            "Mach-O has no file-backed text sections")
    require(len(uuids) <= 1 and len(platforms) <= 1, "Ambiguous Mach-O identity")
    keys = [(section["segment"], section["section"]) for section in sections]
    require(len(set(keys)) == len(keys), "Duplicate Mach-O sections")
    # Distribution symbol stripping can set MH_NLIST_OUTOFSYNC_WITH_DYLDINFO.
    # It describes the mutable nlist table, not the executable code/data.
    return arch, {"cpu": cpu, "subtype": subtype, "filetype": filetype, "flags": flags & ~0x04000000,
                  "uuid": uuids[0] if uuids else None, "platforms": platforms,
                  "dependencies": dependencies, "rpaths": rpaths, "entrypoints": entries,
                  "sections": sections}


def macho_fingerprints(path: Path) -> dict:
    data = path.read_bytes()
    fat_formats = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
                   b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if data[:4] not in fat_formats:
        arch, record = _thin_fingerprint(data)
        return {arch: record}
    endian, wide = fat_formats[data[:4]]
    require(len(data) >= 8, "Truncated fat header")
    count = struct.unpack_from(endian + "I", data, 4)[0]
    entry_size = 32 if wide else 20
    table_end = 8 + count * entry_size
    require(0 < count <= 16 and table_end <= len(data), "Invalid fat architecture table")
    result = {}
    ranges = []
    for index in range(count):
        at = 8 + index * entry_size
        if wide:
            cpu, subtype, offset, size, alignment, reserved = struct.unpack_from(endian + "2I2Q2I", data, at)
            require(reserved == 0, "Invalid fat64 reserved field")
        else:
            cpu, subtype, offset, size, alignment = struct.unpack_from(endian + "5I", data, at)
        require(alignment <= 31 and offset % (1 << alignment) == 0, "Misaligned fat slice")
        require(offset >= table_end and size > 0 and offset + size <= len(data), "Invalid fat slice bounds")
        require(all(offset + size <= start or offset >= end for start, end in ranges), "Overlapping fat slices")
        ranges.append((offset, offset + size))
        arch, record = _thin_fingerprint(data[offset:offset + size])
        require(record["cpu"] == cpu and record["subtype"] == subtype, "Fat/thin CPU identity mismatch")
        require(arch not in result, f"Duplicate {arch} slice")
        result[arch] = record
    return result


def _check_binary(fingerprints: dict, component: dict, platforms: dict) -> None:
    platform = component["platform"]
    require(set(fingerprints) == ARCHES[platform], f"{component['name']}: wrong architecture set")
    settings = platforms[platform]
    for arch, record in fingerprints.items():
        minimum = settings["architecture_minimum_os"][arch]
        expected = {"platform": 4 if platform == "watchos" else 2,
                    "minimum": _version_string(minimum), "sdk": _version_string(settings["sdk_version"])}
        require(record["filetype"] == 2 and record["uuid"], f"{component['name']}/{arch}: missing executable UUID")
        require(record["platforms"] == [expected], f"{component['name']}/{arch}: wrong linked SDK/deployment metadata")
        for _, dependency in record["dependencies"]:
            require(dependency.startswith(("/usr/lib/", "/System/Library/", "@rpath/", "@loader_path/", "@executable_path/")),
                    f"{component['name']}: build-machine dylib dependency {dependency}")
        for _, rpath in record["rpaths"]:
            require(rpath.startswith(("@executable_path/", "@loader_path/", "/usr/lib/swift")),
                    f"{component['name']}: build-machine rpath {rpath}")


def _plist(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as stream:
        plistlib.dump(value, stream, fmt=plistlib.FMT_BINARY)


def _json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def _run(arguments: list, stage: str, log_dir: Path, timeout: int = 120, capture: bool = False):
    return run_command([str(value) for value in arguments], stage=f"xtool-{stage}", timeout=timeout,
                       log_path=log_dir / f"xtool-{stage}.log", capture=capture)


def _merge_info(original: dict, incoming: dict, recursive: bool = False) -> dict:
    merged = deepcopy(original)
    for key, value in incoming.items():
        if key not in merged:
            merged[key] = deepcopy(value)
        elif type(merged[key]) is not type(value):
            raise ValueError(f"Asset plist conflicts with source type for {key}")
        elif isinstance(value, dict):
            if recursive or key == "CFBundleIcons" or key.startswith("CFBundleIcons~"):
                merged[key] = _merge_info(merged[key], value, True)
            else:
                merged[key].update(deepcopy(value))
        elif isinstance(value, list):
            merged[key].extend(item for item in value if item not in merged[key])
        else:
            merged[key] = value
    return merged


def _platform_info(component: dict, manifest: dict, xcode_version: str, machine_build: str) -> dict:
    info = deepcopy(component["info"])
    platform = component["platform"]
    sdk = manifest["platforms"][platform]
    watch = platform == "watchos"
    info.update({"CFBundleInfoDictionaryVersion": "6.0", "CFBundleDevelopmentRegion": "en",
                 "CFBundleSupportedPlatforms": ["WatchOS" if watch else "iPhoneOS"],
                 "UIDeviceFamily": [4] if watch else [1, 2], "MinimumOSVersion": sdk["minimum_os"],
                 "DTPlatformName": platform, "DTPlatformVersion": sdk["sdk_version"],
                 "DTPlatformBuild": sdk["sdk_build"], "DTSDKName": platform + sdk["sdk_version"],
                 "DTSDKBuild": sdk["sdk_build"], "DTXcode": xcode_version,
                 "DTXcodeBuild": manifest["xcode_build"], "BuildMachineOSBuild": machine_build,
                 "DTCompiler": "com.apple.compilers.llvm.clang.1_0"})
    if watch:
        for key in list(info):
            if key in {"LSRequiresIPhoneOS", "UIRequiredDeviceCapabilities", "UILaunchScreen", "CFBundleIconFile"} or key.startswith("UISupportedInterfaceOrientations"):
                info.pop(key)
    else:
        info["LSRequiresIPhoneOS"] = True
        info["UIRequiredDeviceCapabilities"] = ["arm64"]
    return info


def _compile_assets(component: dict, bundle: Path, manifest: dict, intermediates: Path, log_dir: Path) -> dict:
    name = component["name"]
    if name not in {"OTodo", "OTodoWatch"}:
        return {}
    catalog = Path(manifest["root"]) / ("OTodoApp" if name == "OTodo" else name) / "Assets.xcassets"
    require(catalog.is_dir(), f"Missing original catalog {catalog}")
    output = intermediates / name / "assets"
    output.mkdir(parents=True)
    partial = output.parent / "assetcatalog_generated_info.plist"
    arguments = ["xcrun", "actool", catalog, "--compile", output, "--output-format", "human-readable-text",
                 "--notices", "--warnings", "--export-dependency-info", output.parent / "assetcatalog_dependencies",
                 "--output-partial-info-plist", partial, "--app-icon", "AppIcon", "--compress-pngs",
                 "--enable-on-demand-resources", "YES", "--development-region", "en"]
    for device in (["watch"] if component["platform"] == "watchos" else ["iphone", "ipad"]):
        arguments.extend(["--target-device", device])
    arguments.extend(["--minimum-deployment-target", manifest["platforms"][component["platform"]]["minimum_os"],
                      "--platform", component["platform"]])
    _run(arguments, f"assets-{name}", log_dir, 300)
    require((output / "Assets.car").is_file() and (output / "Assets.car").stat().st_size > 0,
            f"{name}: actool did not produce Assets.car")
    shutil.copytree(output, bundle, dirs_exist_ok=True)
    return read_plist(partial)


def _app_intents(component: dict, bundle: Path, manifest: dict, intermediates: Path, log_dir: Path) -> None:
    require(component["name"] == "OTodo", "Only the intent-defining module requires extraction")
    directory = intermediates / "OTodo" / "appintents"
    directory.mkdir(parents=True)
    slice_info = component["slices"][0]
    lists = {"sources": component["source_files"], "const-values": slice_info["const_values"],
             "dependencies": [], "static-dependencies": []}
    require(lists["sources"] and lists["const-values"], "OTodo has no metadata compiler inputs")
    for key in ("sources", "const-values"):
        require(all(Path(item).is_file() and Path(item).stat().st_size > 0 for item in lists[key]),
                f"Missing real AppIntents {key}")
    dependency = Path(slice_info["dependency_info"])
    require(dependency.is_file() and dependency.stat().st_size > 0, "Missing linker dependency_info")
    # This source graph has no dependency-defined intents; lists must exist, but are empty.
    for key, paths in lists.items():
        require(all("\n" not in path and "\r" not in path for path in paths), "Newline in metadata path")
        (directory / key).write_text("".join(path + "\n" for path in paths), encoding="utf-8")
    toolchain = Path(manifest["toolchain_dir"])
    platform = manifest["platforms"]["iphoneos"]
    _run([toolchain / "usr/bin/appintentsmetadataprocessor", "--toolchain-dir", toolchain,
          "--module-name", "OTodo", "--sdk-root", platform["sdk_path"],
          "--xcode-version", manifest["xcode_build"], "--platform-family", platform["platform_family"],
          "--deployment-target", platform["minimum_os"], "--bundle-identifier", component["identifier"],
          "--output", bundle, "--target-triple", slice_info["triple"],
          "--binary-file", bundle / component["info"]["CFBundleExecutable"],
          "--dependency-file", dependency, "--stringsdata-file", directory / "ExtractedAppShortcutsMetadata.stringsdata",
          "--source-file-list", directory / "sources", "--metadata-file-list", directory / "dependencies",
          "--static-metadata-file-list", directory / "static-dependencies", "--swift-const-vals-list", directory / "const-values",
          "--compile-time-extraction", "--deployment-aware-processing", "--validate-assistant-intents",
          "--no-app-shortcuts-localization"], "appintents-extract", log_dir, 300)
    metadata = bundle / "Metadata.appintents"
    for filename in ("extract.actionsdata", "version.json"):
        require((metadata / filename).is_file() and (metadata / filename).stat().st_size > 0,
                f"AppIntents extraction omitted {filename}")
    _run([toolchain / "usr/bin/appintentsnltrainingprocessor", "--infoplist-path", bundle / "Info.plist",
          "--temp-dir-path", directory / "ssu", "--bundle-id", component["identifier"],
          "--product-path", bundle, "--extracted-metadata-path", metadata, "--deployment-postprocessing",
          "--metadata-file-list", directory / "dependencies", "--source-file", bundle / "Info.plist",
          "--archive-ssu-assets"], "appintents-nlu", log_dir, 300)
    nlu = metadata / "nlu"
    require(nlu.is_dir() and any(path.is_file() and path.stat().st_size > 0 for path in nlu.rglob("*")),
            "App Shortcuts NLU training produced no assets")


def _resource_hashes(bundle: Path, executable: str) -> dict:
    result = {}
    for path in sorted(bundle.rglob("*")):
        relative = path.relative_to(bundle)
        if relative.parts[0] in {"PlugIns", "Watch", "Frameworks", "_CodeSignature"}:
            continue
        if relative.as_posix() in {executable, "Info.plist", "embedded.mobileprovision"}:
            continue
        require(not path.is_symlink(), f"Unexpected bundle resource symlink: {path}")
        if path.is_file():
            result[relative.as_posix()] = sha256(path)
    return result


def _required_resources(bundle: Path, component: dict, root: Path | None = None) -> None:
    core = bundle / "OTodoCore_OTodoCore.bundle"
    require(core.is_dir(), f"{bundle}: missing exact SwiftPM Core resource bundle")
    for filename in ("schema.json", "schema-v2.json"):
        resource = core / filename
        require(resource.is_file() and resource.stat().st_size > 0, f"Missing {resource}")
        if root is not None:
            require(sha256(resource) == sha256(root / "Sources/OTodoCore/Resources" / filename),
                    f"Core source resource changed: {resource}")
    if component["name"] == "OTodoShareExtension":
        resource = bundle / "ShareSource.js"
        require(resource.is_file() and resource.stat().st_size > 0, "Missing ShareSource.js")
        if root is not None:
            require(sha256(resource) == sha256(root / "OTodoShareExtension/ShareSource.js"), "ShareSource.js changed")
    if component["name"] in {"OTodo", "OTodoWatch"}:
        require((bundle / "Assets.car").is_file() and (bundle / "Assets.car").stat().st_size > 0, "Missing compiled asset catalog")
        info = read_plist(bundle / "Info.plist")
        require(any(key.startswith("CFBundleIcon") for key in info), f"{bundle}: missing actool icon plist metadata")
    if component["name"] == "OTodo":
        changelog = bundle / "Changelog.json"
        require(changelog.is_file(), "Missing root generated Changelog.json")
        json.loads(changelog.read_text(encoding="utf-8"))
        for name in ("extract.actionsdata", "version.json"):
            path = bundle / "Metadata.appintents" / name
            require(path.is_file() and path.stat().st_size > 0, f"Missing intent metadata {name}")
        nlu = bundle / "Metadata.appintents/nlu"
        require(nlu.is_dir() and any(p.is_file() and p.stat().st_size > 0 for p in nlu.rglob("*")), "Missing NLU assets")


def _uuids(path: Path, stage: str, log_dir: Path) -> dict:
    output = _run(["xcrun", "dwarfdump", "--uuid", path], stage, log_dir, capture=True)
    matches = re.findall(r"UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", output)
    require(matches and len(matches) == len({arch for _, arch in matches}), f"Missing/duplicate dSYM UUID: {path}")
    return {arch: value.replace("-", "").lower() for value, arch in matches}


def _runtime_libraries(app: Path) -> dict:
    libraries = {}
    for framework_dir in sorted(app.rglob("Frameworks")):
        for path in sorted(framework_dir.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            with path.open("rb") as stream:
                magic = stream.read(4)
            if magic in {b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf",
                         b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}:
                libraries[path.relative_to(app).as_posix()] = {"sha256": sha256(path), "fingerprints": macho_fingerprints(path)}
    return libraries


def assemble(manifest: dict, archive: Path, log_dir: Path) -> dict:
    """Consume the producer's schema-1 compile manifest without recompiling Swift."""
    require(manifest.get("schema") == 1 and manifest.get("configuration") == "release", "Expected release compile manifest schema 1")
    root, workspace = Path(manifest["root"]), Path(manifest["workspace"])
    archive, log_dir = archive.resolve(), log_dir.resolve()
    require(not archive.exists(), f"Archive already exists: {archive}")
    require({item["name"] for item in manifest["components"]} == {item[0] for item in COMPONENTS}
            and len(manifest["components"]) == len(COMPONENTS), "Compile manifest must contain exactly five components")
    for platform, expected in (("iphoneos", "17.0"), ("watchos", "10.0")):
        require(manifest["platforms"][platform]["minimum_os"] == expected, f"Wrong {platform} deployment target")
        require(_version_string(manifest["platforms"][platform]["sdk_version"])[0] >= 26, "App Store requires SDK 26 or newer")
    log_dir.mkdir(parents=True, exist_ok=True)
    xcode_output = _run(["xcodebuild", "-version"], "xcode-identity", log_dir, capture=True)
    match = re.search(r"^Xcode (\d+)\.(\d+)(?:\.(\d+))?\s*$", xcode_output, re.MULTILINE)
    require(match is not None and f"Build version {manifest['xcode_build']}" in xcode_output, "Processing Xcode differs from compiler Xcode")
    xcode_version = f"{int(match[1]):02d}{int(match[2])}{int(match[3] or 0)}"
    machine_build = _run(["sw_vers", "-buildVersion"], "machine-build", log_dir, capture=True).strip()
    require(machine_build, "Missing macOS build identity")
    app = archive / "Products/Applications/OTodo.app"
    intermediates = workspace / "archive-intermediates"
    require(not intermediates.exists(), f"Stale archive intermediates: {intermediates}")
    intermediates.mkdir(parents=True)
    records = []
    for target, identifier, relative, entitlements, _ in COMPONENTS:
        component = next(item for item in manifest["components"] if item["name"] == target)
        require(component["identifier"] == identifier and component["relative_path"] == relative,
                f"{target}: compile manifest component identity changed")
        require(Path(component["entitlements_path"]).resolve() == (root / entitlements).resolve(), f"{target}: wrong entitlement source")
        require(component["platform"] == ("watchos" if target.startswith("OTodoWatch") else "iphoneos"), f"{target}: wrong platform")
        slices = component["slices"]
        require(len(slices) == len(ARCHES[component["platform"]]) and {item["arch"] for item in slices} == ARCHES[component["platform"]],
                f"{target}: incomplete xtool slices")
        compiled = {}
        raw_hashes = {}
        linker_inputs = {}
        for item in slices:
            binary = Path(item["binary"])
            actual = macho_fingerprints(binary)
            require(set(actual) == {item["arch"]}, f"{target}: input must be a single matching slice")
            compiled.update(actual)
            raw_hashes[item["arch"]] = sha256(binary)
            linker_inputs[item["arch"]] = {
                "dependency_info_sha256": sha256(Path(item["dependency_info"])),
                "const_values_sha256": {path: sha256(Path(path)) for path in item["const_values"]},
            }
            require(Path(item["build_directory"]).is_dir(), f"{target}: missing compiler object directory")
        _check_binary(compiled, component, manifest["platforms"])
        bundle = app / relative
        packed = Path(slices[0]["bundle"])
        require(packed.is_dir(), f"Missing xtool packed bundle: {packed}")
        shutil.copytree(packed, bundle, ignore=shutil.ignore_patterns("PlugIns", "Watch", "_CodeSignature", "embedded.mobileprovision"))
        executable = component["info"]["CFBundleExecutable"]
        require(isinstance(executable, str) and Path(executable).name == executable and executable not in {".", ".."}, "Unsafe executable name")
        binary = bundle / executable
        if len(slices) == 1:
            shutil.copy2(Path(slices[0]["binary"]), binary)
        else:
            _run(["xcrun", "lipo", "-create", *[item["binary"] for item in slices], "-output", binary], f"lipo-{target}", log_dir)
        binary.chmod(0o755)
        require(macho_fingerprints(binary) == compiled, f"{target}: assembly changed compiled sections")
        info = _platform_info(component, manifest, xcode_version, machine_build)
        info = _merge_info(info, _compile_assets(component, bundle, manifest, intermediates, log_dir))
        _plist(bundle / "Info.plist", info)
        (bundle / "PkgInfo").write_bytes((info["CFBundlePackageType"] + "????").encode("ascii"))
        dsym = archive / "dSYMs" / (bundle.name + ".dSYM")
        dsym.parent.mkdir(parents=True, exist_ok=True)
        _run(["xcrun", "dsymutil", binary, "-o", dsym], f"dsym-{target}", log_dir, 300)
        uuid_map = _uuids(dsym, f"dsym-uuid-{target}", log_dir)
        require(uuid_map == {arch: record["uuid"] for arch, record in compiled.items()}, f"{target}: dSYM UUIDs differ from compiled products")
        records.append({**deepcopy(component), "info": info, "compiled_fingerprints": compiled,
                        "initial_binary_sha256": raw_hashes, "assembled_binary_sha256": sha256(binary),
                        "entitlements_sha256": sha256(Path(component["entitlements_path"])),
                        "linker_inputs": linker_inputs,
                        "dsym": str(dsym), "dsym_uuids": uuid_map})
    main = next(item for item in records if item["name"] == "OTodo")
    _app_intents(main, app, manifest, intermediates, log_dir)
    for target in ("OTodoWatch", "OTodo"):
        component = next(item for item in records if item["name"] == target)
        bundle = app / component["relative_path"]
        frameworks = bundle / "Frameworks"
        frameworks.mkdir(exist_ok=True)
        support = archive / "SwiftSupport" / component["platform"]
        support.mkdir(parents=True)
        _run(["xcrun", "swift-stdlib-tool", "--copy", "--verbose", "--scan-executable", bundle / component["info"]["CFBundleExecutable"],
              "--scan-folder", frameworks, "--scan-folder", bundle / "PlugIns", "--platform", component["platform"],
              "--destination", frameworks, "--unsigned-destination", support,
              "--filter-for-swift-os", "--back-deploy-swift-span"], f"swift-runtime-{target}", log_dir, 300)
    for component in records:
        bundle = app / component["relative_path"]
        _required_resources(bundle, component, root)
        component["resource_sha256"] = _resource_hashes(bundle, component["info"]["CFBundleExecutable"])
    libraries = _runtime_libraries(app)
    support_hashes = {path.relative_to(archive).as_posix(): sha256(path)
                      for path in sorted((archive / "SwiftSupport").rglob("*")) if path.is_file()}
    asset_sources = {}
    for catalog in (root / "OTodoApp/Assets.xcassets", root / "OTodoWatch/Assets.xcassets"):
        for path in sorted(catalog.rglob("*")):
            if path.is_file():
                asset_sources[path.relative_to(root).as_posix()] = sha256(path)
    result = {**deepcopy(manifest), "components": records, "archive_path": str(archive),
              "signing_state": "ad-hoc intermediate; not distribution", "team": TEAM,
              "asset_source_sha256": asset_sources,
              "runtime_libraries": libraries, "swift_support_sha256": support_hashes}
    manifest_path = log_dir / "xtool-archive.json"
    # Retain original product hashes and all pre-sign provenance even if signing fails.
    _json(manifest_path, result)
    signables = set()
    for relative in libraries:
        path = app / relative
        framework = next((parent for parent in path.parents if parent.suffix == ".framework"), None)
        signables.add(framework or path)
    for index, path in enumerate(sorted(signables, key=lambda item: len(item.parts), reverse=True)):
        _run(["codesign", "--force", "--sign", "-", "--generate-entitlement-der", path], f"sign-library-{index}", log_dir)
    for component in sorted(records, key=lambda item: len(Path(item["relative_path"]).parts), reverse=True):
        bundle = app / component["relative_path"]
        _run(["codesign", "--force", "--sign", "-", "--entitlements", component["entitlements_path"],
              "--generate-entitlement-der", bundle], f"sign-{component['name']}", log_dir)
        require(macho_fingerprints(bundle / component["info"]["CFBundleExecutable"]) == component["compiled_fingerprints"],
                f"{component['name']}: ad-hoc signing changed machine code/data")
    _plist(archive / "Info.plist", {"ArchiveVersion": 2, "CreationDate": datetime.now(timezone.utc).replace(tzinfo=None),
           "Name": "OTodo", "SchemeName": "OTodo", "ApplicationProperties": {
               "ApplicationPath": "Applications/OTodo.app", "Architectures": ["arm64"],
               "CFBundleIdentifier": main["identifier"], "CFBundleShortVersionString": manifest["version"],
               "CFBundleVersion": manifest["build"], "SigningIdentity": "-", "Team": TEAM}})
    validate_built(app, "archive", manifest["version"], manifest["build"])
    result["archive_validated"] = True
    _json(manifest_path, result)
    return result


def _extract_ipa(ipa: Path, destination: Path) -> None:
    with zipfile.ZipFile(ipa) as archive:
        seen = set()
        total = 0
        for member in archive.infolist():
            path = PurePosixPath(member.filename)
            require(member.filename and not path.is_absolute() and ".." not in path.parts and "\\" not in member.filename,
                    f"Unsafe IPA member: {member.filename}")
            normalized = path.as_posix().casefold()
            require(normalized not in seen, f"Duplicate IPA member: {member.filename}")
            seen.add(normalized)
            mode = member.external_attr >> 16
            require(not stat.S_ISLNK(mode) and stat.S_IFMT(mode) in {0, stat.S_IFREG, stat.S_IFDIR}, "IPA contains a link or special file")
            total += member.file_size
            require(total <= 8 * 1024 ** 3, "IPA exceeds extraction size limit")
            target = destination.joinpath(*path.parts)
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(mode & 0o777 if mode & 0o777 else 0o644)


def _allowed_entitlement(claim, allowance) -> bool:
    if isinstance(claim, str) and isinstance(allowance, str):
        return fnmatch.fnmatchcase(claim, allowance)
    if isinstance(claim, list) and isinstance(allowance, list):
        return all(any(_allowed_entitlement(item, allowed) for allowed in allowance) for item in claim)
    if isinstance(claim, dict) and isinstance(allowance, dict):
        return all(key in allowance and _allowed_entitlement(value, allowance[key]) for key, value in claim.items())
    return type(claim) is type(allowance) and claim == allowance


def _distribution(bundle: Path, identifier: str, stage: str, scratch: Path, log_dir: Path) -> dict:
    # A valid ad-hoc signature passes codesign --verify; require the Apple anchor too.
    _run(["codesign", "--verify", "--strict", "-R", f'anchor apple generic and certificate leaf[subject.OU] = "{TEAM}"', bundle],
         f"export-trust-{stage}", log_dir)
    _run(["codesign", "--display", "--verbose=4", bundle], f"export-signature-{stage}", log_dir)
    # codesign's descriptive output is stderr; ci_runtime capture deliberately returns only stdout.
    signature = (log_dir / f"xtool-export-signature-{stage}.log").read_text(encoding="utf-8")
    require(re.search(r"^Authority=(?:Apple Distribution|iPhone Distribution):", signature, re.MULTILINE),
            f"{bundle}: not an Apple distribution authority")
    require(f"TeamIdentifier={TEAM}" in signature and "Signature=adhoc" not in signature, f"{bundle}: wrong signature team/type")
    entitlement_xml = _run(["codesign", "--display", "--entitlements", ":-", bundle], f"export-entitlements-{stage}", log_dir, capture=True)
    entitlements = plistlib.loads(entitlement_xml.encode("utf-8"))
    validate_groups(entitlements, str(bundle))
    require(entitlements.get("get-task-allow", False) is False, f"{bundle}: development debugging entitlement")
    require(entitlements.get("com.apple.developer.team-identifier") == TEAM, f"{bundle}: effective team mismatch")
    profile_path = bundle / "embedded.mobileprovision"
    require(profile_path.is_file(), f"{bundle}: no distribution provisioning profile")
    # Decoding exposes profile claims; security cms -D is not CMS authenticity proof.
    # release.py must run Apple's authenticated validate-app before upload.
    profile_xml = _run(["security", "cms", "-D", "-i", profile_path],
                       f"export-profile-{stage}", log_dir, capture=True)
    profile = plistlib.loads(profile_xml.encode("utf-8"))
    now = datetime.now(timezone.utc)
    expiry, creation = profile.get("ExpirationDate"), profile.get("CreationDate")
    require(isinstance(expiry, datetime) and expiry.replace(tzinfo=timezone.utc) > now, f"{bundle}: expired/invalid profile")
    require(isinstance(creation, datetime) and creation.replace(tzinfo=timezone.utc) <= now, f"{bundle}: future/invalid profile")
    require("ProvisionedDevices" not in profile and "ProvisionsAllDevices" not in profile, f"{bundle}: not an App Store profile")
    require(profile.get("TeamIdentifier") == [TEAM], f"{bundle}: profile team mismatch")
    allowed = profile.get("Entitlements", {})
    require(allowed.get("get-task-allow") is False and allowed.get("beta-reports-active") is True,
            f"{bundle}: profile lacks App Store distribution entitlements")
    require(allowed.get("com.apple.developer.team-identifier") == TEAM, f"{bundle}: profile entitlement team mismatch")
    app_id = entitlements.get("application-identifier")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    require(isinstance(app_id, str) and any(app_id == prefix + "." + identifier for prefix in prefixes), f"{bundle}: invalid application identifier prefix")
    require(allowed.get("application-identifier") == app_id, f"{bundle}: profile is not for this explicit app identifier")
    for key, claim in entitlements.items():
        require(key in allowed and _allowed_entitlement(claim, allowed[key]), f"{bundle}: profile does not authorize {key}")
    certificate_prefix = scratch / (stage + "-certificate-")
    _run(["codesign", "--display", "--extract-certificates", certificate_prefix, bundle], f"export-certificate-{stage}", log_dir)
    leaf = Path(str(certificate_prefix) + "0")
    require(leaf.is_file(), f"{bundle}: signature has no leaf certificate")
    certificates = profile.get("DeveloperCertificates")
    require(isinstance(certificates, list) and leaf.read_bytes() in certificates,
            f"{bundle}: actual signer is not the profile distribution certificate")
    return {"profile_uuid": profile.get("UUID"), "profile_sha256": sha256(profile_path),
            "expires": expiry.isoformat() + "Z", "certificate_sha256": sha256(leaf),
            "application_identifier": app_id, "team": TEAM}


def verify_export(ipa: Path, manifest_path: Path) -> dict:
    """Check native signatures, profile claims and exact compiled slice identity.

    Apple's authenticated validate-app remains required for provisioning acceptance.
    """
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    require(manifest.get("schema") == 1 and manifest.get("archive_validated") is True, "Archive manifest is not validated")
    log_dir = Path(required_environment("RELEASE_LOG_DIR"))
    log_dir.mkdir(parents=True, exist_ok=True)
    require(len(manifest["components"]) == 5 and {item["name"] for item in manifest["components"]} == {item[0] for item in COMPONENTS},
            "Archive manifest does not describe all five components")
    result = {"schema": 1, "ipa": str(ipa.resolve()), "ipa_sha256": sha256(ipa),
              "archive_manifest": str(manifest_path.resolve()), "archive_manifest_sha256": sha256(manifest_path),
              "source_sha": manifest["source_sha"], "version": manifest["version"], "build": manifest["build"], "components": []}
    with tempfile.TemporaryDirectory(prefix="xtool-export-") as temporary:
        directory = Path(temporary)
        _extract_ipa(ipa, directory)
        app = directory / "Payload/OTodo.app"
        require(list((directory / "Payload").glob("*.app")) == [app], "IPA must contain exactly OTodo.app")
        actual_bundles = {path.relative_to(app).as_posix() for path in app.rglob("*") if path.suffix in {".app", ".appex"} and path.is_dir()} | {"."}
        require(actual_bundles == {item[2] for item in COMPONENTS}, "Exported bundle graph differs from the five original components")
        validate_built(app, "archive", manifest["version"], manifest["build"])
        for component in manifest["components"]:
            target, identifier, relative, _, _ = next(item for item in COMPONENTS if item[0] == component["name"])
            require(component["relative_path"] == relative and component["identifier"] == identifier, "Archive manifest identity mismatch")
            bundle = app / relative
            info = read_plist(bundle / "Info.plist")
            # Export may add store bookkeeping; it must not remove/change assembled source/SDK/icon metadata.
            for key, expected in component["info"].items():
                require(info.get(key) == expected, f"{target}: export changed required plist key {key}")
            fingerprints = macho_fingerprints(bundle / info["CFBundleExecutable"])
            _check_binary(fingerprints, component, manifest["platforms"])
            require(fingerprints == component["compiled_fingerprints"], f"{target}: exported machine code/data differs from xtool products")
            _required_resources(bundle, component)
            for resource, expected in component["resource_sha256"].items():
                path = bundle / resource
                require(path.is_file() and sha256(path) == expected, f"{target}: exported resource changed/missing: {resource}")
            distribution = _distribution(bundle, identifier, target, directory, log_dir)
            result["components"].append({"name": target, "architectures": sorted(fingerprints), "code_data_match": True, **distribution})
        libraries = _runtime_libraries(app)
        require(set(libraries) == set(manifest["runtime_libraries"]), "Export changed the runtime library inventory")
        for index, (relative, record) in enumerate(libraries.items()):
            require(record["fingerprints"] == manifest["runtime_libraries"][relative]["fingerprints"], f"Runtime code/data changed: {relative}")
            _run(["codesign", "--verify", "--strict", "-R", "anchor apple generic", app / relative], f"export-runtime-{index}", log_dir)
        for relative, expected in manifest["swift_support_sha256"].items():
            path = directory / relative
            require(path.is_file() and sha256(path) == expected, f"Export omitted/changed unsigned SwiftSupport: {relative}")
    result["local_export_checks_passed"] = True
    result["profile_validation"] = "decoded claims inspected; CMS authenticity not established locally"
    result["apple_validation_required"] = True
    _json(log_dir / "xtool-export.json", result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["build"])
    parser.parse_args()
    import xtool_build

    root = Path.cwd().resolve()
    workspace = Path(required_environment("RUNNER_TEMP")) / "xtool-release"
    manifest = xtool_build.build(root, workspace, required_environment("MARKETING_VERSION"),
                                 required_environment("BUILD_NUMBER"), required_environment("GITHUB_CLIENT_ID"))
    log_dir = Path(required_environment("RELEASE_LOG_DIR")).resolve()
    assemble(manifest, Path(required_environment("ARCHIVE_PATH")), log_dir)
    manifest_path = str(log_dir / "xtool-archive.json")
    require("\n" not in manifest_path and "\r" not in manifest_path, "Invalid archive manifest environment path")
    with Path(required_environment("GITHUB_ENV")).open("a", encoding="utf-8") as stream:
        stream.write(f"XTOOL_ARCHIVE_MANIFEST={manifest_path}\n")
    print(f"Prepared xtool archive; distribution export remains required. Manifest: {manifest_path}")


if __name__ == "__main__":
    try:
        main()
    except CommandError as error:
        annotate("error", str(error), title="xtool archive")
        raise SystemExit(error.returncode)
    except Exception as error:
        annotate("error", str(error), title="xtool archive")
        raise SystemExit(1)
