#!/usr/bin/env python3
"""Stage original OTodo sources and compile device products through pinned xtool."""

import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sys

import yaml

from ci_runtime import CommandError, annotate, run_command
from validate_bundles import COMPONENTS, VERSION_PATTERN, load_project, require, validate_source

XTOOL_VERSION = "1.19.2"
XTOOL_URL = f"https://github.com/xtool-org/xtool/releases/download/{XTOOL_VERSION}/xtool.app.zip"
XTOOL_SHA256 = "884d7a71dbfc1259abe78296b872fadbccbc88f09798231acaf8228fd7ebabaf"
WATCH_SHARED = {"OTodoShared/SharedWorkspaceStorage.swift", "OTodoShared/WatchSnapshotStorage.swift"}
PLATFORMS = {
    "iphoneos": {"minimum_os": "17.0", "platform_family": "iOS", "architecture_minimum_os": {"arm64": "17.0"}},
    # Native arm64 watchOS starts at 26; arm64_32 retains the project's watchOS 10 support.
    "watchos": {"minimum_os": "10.0", "platform_family": "watchOS",
                "architecture_minimum_os": {"arm64": "26.0", "arm64_32": "10.0"}},
}


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def command(manifest: dict, arguments: list[str], stage: str, *, cwd=None, env=None, timeout=120) -> str:
    log = Path(os.environ.get("RELEASE_LOG_DIR", str(Path(manifest["workspace"]) / "logs"))) / f"{stage}.log"
    manifest.setdefault("commands", []).append({"arguments": arguments, "cwd": str(cwd or manifest["root"]), "log": str(log)})
    return run_command(arguments, stage=stage, timeout=timeout, capture=True,
                       cwd=cwd or manifest["root"], env=env, log_path=log).strip()


def source_membership(root: Path, name: str, definition: dict) -> tuple[list[Path], list[Path]]:
    """Interpret this project's XcodeGen source declarations; reject unknown semantics."""
    swift, resources = set(), set()
    for entry in definition["sources"]:
        entry = {"path": entry} if isinstance(entry, str) else entry
        require(set(entry) <= {"path", "excludes", "includes", "buildPhase"},
                f"{name}: unsupported XcodeGen source options: {entry}")
        require(entry.get("buildPhase") in {None, "sources", "resources", "none"},
                f"{name}: unsupported source build phase")
        base = root / entry["path"]
        require(base.exists() and base.resolve().is_relative_to(root), f"{name}: missing or external source {base}")
        candidates = [base] if base.is_file() else sorted(base.rglob("*"))
        matched = 0
        for path in candidates:
            relative = path.relative_to(base).as_posix() if base.is_dir() else path.name
            # Match directory exclusions as well as the files beneath them.
            parts = [relative, *[p.as_posix() for p in Path(relative).parents if p.as_posix() != "."]]
            if any(fnmatch.fnmatchcase(part, pattern) for pattern in entry.get("excludes", []) for part in parts):
                continue
            if "includes" in entry and not any(fnmatch.fnmatchcase(relative, pattern) for pattern in entry["includes"]):
                continue
            if entry.get("buildPhase") == "none":
                continue
            require(path.resolve().is_relative_to(root), f"{name}: external source symlink {path}")
            if path.suffix == ".xcassets" and path.is_dir():
                resources.add(path)
                matched += 1
            elif path.is_file() and not any(p.suffix == ".xcassets" for p in path.parents):
                if path.suffix == ".swift" and entry.get("buildPhase") != "resources":
                    swift.add(path)
                    matched += 1
                elif path.suffix not in {".plist", ".entitlements", ".swift"} and not path.name.startswith("."):
                    resources.add(path)
                    matched += 1
        require(matched > 0, f"{name}: empty source declaration {entry['path']}")
    require(bool(swift), f"{name}: no Swift source members")
    if name.startswith("OTodoWatch"):
        shared = {p.relative_to(root).as_posix() for p in swift if p.relative_to(root).parts[0] == "OTodoShared"}
        require(shared == WATCH_SHARED, f"{name}: watch shared membership changed: {sorted(shared)}")
    return sorted(swift), sorted(resources)


def resolve_settings(value, settings: dict):
    if isinstance(value, dict):
        return {key: resolve_settings(item, settings) for key, item in value.items()}
    if isinstance(value, list):
        return [resolve_settings(item, settings) for item in value]
    if not isinstance(value, str):
        return value
    def replace(match):
        key = match.group(1) or match.group(2)
        require(key in settings, f"Unknown Info.plist build setting {key}")
        return str(settings[key])
    result = re.sub(r"\$\(([^)]+)\)|\$\{([^}]+)\}", replace, value)
    require("$(" not in result and "${" not in result, f"Unresolved Info.plist setting: {result}")
    return result


def protocol_array(path: Path) -> list[str]:
    value = json.loads(path.read_text())
    require(isinstance(value, list) and bool(value) and all(isinstance(item, str) and item for item in value),
            f"{path}: compiler protocols must be a nonempty bare string array")
    return sorted(set(value))


def package_source(root: Path, components: list[dict], protocols_file: Path | None, workspace: Path) -> str:
    products, targets = [], []
    for component in components:
        name = component["name"]
        products.append(f'.library(name: {json.dumps(name)}, targets: [{json.dumps(name)}])')
        flags = ["-g"]
        if component["extension_point"]:
            flags.append("-application-extension")
        if name == "OTodo" and protocols_file is not None:
            flags += ["-emit-const-values", "-emit-const-values-path", str(workspace / "metadata/OTodo.swiftconstvalues"),
                      "-Xfrontend", "-const-gather-protocols-file", "-Xfrontend", str(protocols_file)]
        frameworks = component["frameworks"]
        linker = ", linkerSettings: [" + ", ".join(f'.linkedFramework({json.dumps(f)})' for f in frameworks) + "]" if frameworks else ""
        targets.append(f'.target(name: {json.dumps(name)}, dependencies: [.product(name: "OTodoCore", package: "OTodoCore")], '
                       f'swiftSettings: [.unsafeFlags({json.dumps(flags)})]{linker})')
    return ('// swift-tools-version: 6.1\nimport PackageDescription\nlet package = Package(\n'
            '    name: "OTodoXtool",\n    platforms: [.iOS(.v17), .watchOS(.v10)],\n'
            '    products: [' + ",\n        ".join(products) + '],\n'
            f'    dependencies: [.package(name: "OTodoCore", path: {json.dumps(str(root))})],\n'
            '    targets: [' + ",\n        ".join(targets) + '],\n    swiftLanguageModes: [.v6]\n)\n')


def prepare(root: Path, workspace: Path, version: str, build_number: str, client_id: str, protocols_file=None) -> dict:
    """Portable preparation only: no Apple tools, tool installation, or compilation."""
    root, workspace = Path(root).resolve(), Path(workspace).resolve()
    require(re.fullmatch(VERSION_PATTERN, version) is not None, "Invalid marketing version")
    require(re.fullmatch(r"[0-9]+", build_number) is not None, "Invalid build number")
    require(isinstance(client_id, str) and bool(client_id.strip()), "GITHUB_CLIENT_ID is required")
    validate_source(root)
    project = load_project(root)
    stage = workspace / "source"
    require(not stage.exists(), f"Refusing to reuse staged sources: {stage}; choose a clean workspace")
    if protocols_file is not None:
        protocols_file = Path(protocols_file).resolve()
        protocol_array(protocols_file)
    stage.mkdir(parents=True)
    (workspace / "metadata").mkdir(exist_ok=True)
    manifest = {"schema": 1, "root": str(root), "workspace": str(workspace), "version": version, "build": build_number,
                "configuration": "release", "swift_version": "", "toolchain_dir": "", "xcode_build": "",
                "platforms": {name: {**data, "sdk_path": "", "sdk_version": "", "sdk_build": ""} for name, data in PLATFORMS.items()},
                "components": [], "xtool": {"version": XTOOL_VERSION, "url": XTOOL_URL, "sha256": XTOOL_SHA256},
                "core_package": {"path": str(root / "Package.swift"), "sha256": digest(root / "Package.swift")}}
    manifest["core_package"]["source_inputs"] = [
        {"source": path.relative_to(root).as_posix(), "sha256": digest(path)}
        for path in sorted((root / "Sources/OTodoCore").rglob("*")) if path.is_file()
    ]
    manifest["source_sha"] = command(manifest, ["git", "rev-parse", "HEAD"], "xtool-source-sha")
    require(re.fullmatch(r"[0-9a-f]{40}", manifest["source_sha"]) is not None, "Invalid source Git SHA")
    for name, identifier, relative, entitlements, extension_point in COMPONENTS:
        definition = project["targets"][name]
        base = definition["settings"]["base"]
        require(str(base.get("SWIFT_VERSION")) == "6.0", f"{name}: Swift 6 language mode is required")
        platform = "watchos" if definition["platform"] == "watchOS" else "iphoneos"
        require(str(definition["deploymentTarget"]) == PLATFORMS[platform]["minimum_os"], f"{name}: unexpected minimum OS")
        sources, resources = source_membership(root, name, definition)
        settings = {**base, "MARKETING_VERSION": version, "CURRENT_PROJECT_VERSION": build_number,
                    "GITHUB_CLIENT_ID": client_id, "PRODUCT_MODULE_NAME": name, "PRODUCT_NAME": name}
        info = resolve_settings(definition["info"]["properties"], settings)
        info.update(CFBundleExecutable=name, CFBundleName=name, CFBundleIdentifier=identifier,
                    CFBundlePackageType="XPC!" if extension_point else "APPL", CFBundleInfoDictionaryVersion="6.0",
                    CFBundleDevelopmentRegion="en", CFBundleShortVersionString=version, CFBundleVersion=build_number,
                    MinimumOSVersion=PLATFORMS[platform]["minimum_os"])
        source_inputs = []
        for source in sources:
            target = stage / platform / "Sources" / name / source.relative_to(root)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            checksum = digest(source)
            require(digest(target) == checksum, f"Source staging changed {source}")
            source_inputs.append({"source": source.relative_to(root).as_posix(), "staged": str(target), "sha256": checksum})
        resource_inputs = []
        for resource in resources:
            target = stage / platform / "Resources" / name / resource.relative_to(root)
            target.parent.mkdir(parents=True, exist_ok=True)
            if resource.is_dir():
                shutil.copytree(resource, target)
            else:
                shutil.copy2(resource, target)
            resource_inputs.append({"source": resource.relative_to(root).as_posix(), "staged": str(target)})
        frameworks = []
        for dependency in definition["dependencies"]:
            require(set(dependency) <= {"package", "product", "target", "embed", "link", "copy", "sdk"},
                    f"{name}: unsupported dependency declaration")
            if "package" in dependency:
                require(dependency == {"package": "OTodoCore", "product": "OTodoCore"}, f"{name}: unsupported package dependency")
            if "sdk" in dependency:
                require(dependency["sdk"].endswith(".framework"), f"{name}: unsupported SDK dependency")
                frameworks.append(dependency["sdk"].removesuffix(".framework"))
        component = {"name": name, "identifier": identifier, "relative_path": relative, "platform": platform,
                     "entitlements_path": str(root / entitlements), "info": info, "source_files": [item["staged"] for item in source_inputs],
                     "source_inputs": source_inputs, "resource_inputs": resource_inputs, "extension_point": extension_point,
                     "frameworks": frameworks, "slices": []}
        manifest["components"].append(component)
    changelog = stage / "iphoneos/Resources/Changelog.json"
    command(manifest, [sys.executable, str(root / ".github/scripts/generate_changelog.py"), str(changelog)], "xtool-changelog")
    for platform in PLATFORMS:
        package = stage / platform
        components = [c for c in manifest["components"] if c["platform"] == platform]
        (package / "Package.swift").write_text(package_source(root, components, protocols_file, workspace))
        config_dir = package / "Configuration"
        config_dir.mkdir()
        records = []
        for component in components:
            name = component["name"]
            plist = config_dir / f"{name}.plist"
            plist.write_bytes(plistlib.dumps(component["info"]))
            # entitlementsPath would make xtool sign ad hoc even without --sign.
            # The archive consumer owns all signing, using the original paths in the manifest.
            record = {"product": name, "bundleID": component["identifier"], "infoPath": str(plist.relative_to(package))}
            # Catalogs are preserved for the archive owner's actool pass, not copied raw into the app.
            resources = [str(Path(item["staged"]).relative_to(package)) for item in component["resource_inputs"]
                         if Path(item["staged"]).suffix != ".xcassets"]
            if name == "OTodo":
                resources.append(str(changelog.relative_to(package)))
            if resources:
                record["resources"] = resources
            records.append(record)
        config = {"version": 1, **records[0], "extensions": records[1:]}
        (package / "xtool.yml").write_text(yaml.safe_dump(config, sort_keys=False))
    (workspace / "xtool-prepare.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def adapt_recipe(content: str, components: list[dict], platform: str, dependency_dir: Path, minimum_os: str) -> str:
    """Patch only the pinned generated C wrappers; preserve Foundation extension startup."""
    platform_match = re.findall(r'\.iOS\("[0-9.]+"\)', content)
    require(len(platform_match) == 1, "Unexpected pinned xtool generated platform recipe")
    replacement = f'.{"watchOS" if platform == "watchos" else "iOS"}("{minimum_os}")'
    content = content.replace(platform_match[0], replacement)
    starts = [match.start() for match in re.finditer(r"\.executableTarget\(", content)]
    require(len(starts) == len(components), "Unexpected xtool executable wrapper count")
    for index in reversed(range(len(starts))):
        start = starts[index]
        end = starts[index + 1] if index + 1 < len(starts) else len(content)
        target = content[start:end]
        matches = [c for c in components if f'name: "{c["name"]}-{"Extension" if c["extension_point"] else "App"}"' in target]
        require(len(matches) == 1, "Unknown xtool executable wrapper")
        component = matches[0]
        require(target.count(".unsafeFlags([") == 1, "Unexpected xtool linker recipe")
        flags = ["-Xlinker", "-dependency_info", "-Xlinker", str(dependency_dir / f'{component["name"]}.dat'),
                 "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift"]
        if component["extension_point"]:
            require(target.count('"_NSExtensionMain"') == 1 and '"_main"' not in target,
                    "xtool extension must use canonical _NSExtensionMain")
            flags += ["-Xlinker", "-application_extension"]
        target = target.replace(".unsafeFlags([", ".unsafeFlags([\n" + ", ".join(json.dumps(flag) for flag in flags) + ",")
        content = content[:start] + target + content[end:]
    return content


def option_values(arguments: list[str], *names: str) -> list[str]:
    values = []
    for index, argument in enumerate(arguments):
        if argument in names:
            require(index + 1 < len(arguments), f"Missing {argument} value")
            values.append(arguments[index + 1])
        for name in names:
            if argument.startswith(name + "="):
                values.append(argument.split("=", 1)[1])
    return values


def swiftpm_proxy(tool: str, arguments: list[str]) -> None:
    """xtool's custom-bin entry: constrain native SwiftPM and retain exact invocations."""
    config = json.loads(Path(os.environ["OTODO_XTOOL_PROXY_CONFIG"]).read_text())
    require(tool in {"build", "package"}, "Unexpected SwiftPM proxy command")
    require(option_values(arguments, "--configuration", "-c") == ["release"], "xtool must build Release")
    require(option_values(arguments, "--swift-sdk") == [config["triple"]], "xtool must use one selected SDK triple")
    require(not option_values(arguments, "--arch", "--triple", "--build-system"), "Do not override xtool's native single-triple backend")
    packages = option_values(arguments, "--package-path")
    require(bool(packages), "xtool omitted package path")
    package = Path(packages[-1]).resolve()
    if tool == "build":
        require(package == Path(config["package"]) / "xtool/.xtool-tmp", "Only xtool's generated wrapper package may compile")
        manifest_path = package / "Package.swift"
        content = adapt_recipe(manifest_path.read_text(), config["components"], config["platform"],
                               Path(config["dependency_dir"]), config["minimum_os"])
        manifest_path.write_text(content)
        Path(config["recipe_path"]).write_text(content)
        arguments += ["--build-system", "native", "-Xswiftc", "-g", "-Xcc", "-g", "--disable-local-rpath"]
    else:
        require("describe" in arguments or "show-dependencies" in arguments,
                "Only xtool's read-only SwiftPM planning commands are allowed")
        # Planner describes the original Core package and resolved dependencies too.
        require((package / "Package.swift").is_file(), f"Missing planned package manifest: {package}")
    executable = config["swift"]
    invocation = [executable, tool, *arguments]
    with Path(config["commands_path"]).open("a") as output:
        output.write(json.dumps({"arguments": invocation, "cwd": str(Path.cwd())}) + "\n")
    environment = dict(os.environ)
    for key in ("SWIFTPM_CUSTOM_BIN_DIR", "SDKROOT", "OTODO_XTOOL_PROXY_CONFIG"):
        environment.pop(key, None)
    # Exec keeps SwiftPM in the bounded outer ci_runtime command's process group.
    os.execvpe(executable, invocation, environment)


def build(root: Path, workspace: Path, version: str, build_number: str, client_id: str) -> dict:
    require(sys.platform == "darwin", "Native xtool Release compilation requires macOS with full Xcode")
    root, workspace = Path(root).resolve(), Path(workspace).resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    identities = {"root": str(root), "workspace": str(workspace), "commands": []}
    # Preserve the swift multicall executable name; resolving its symlink changes dispatch.
    swift = Path(command(identities, ["xcrun", "--find", "swift"], "xtool-find-swift")).absolute()
    toolchain = swift.parents[2]
    require(toolchain.name == "XcodeDefault.xctoolchain", "Select the full Xcode default Swift toolchain")
    swift_version = command(identities, [str(swift), "--version"], "xtool-swift-version")
    match = re.search(r"Swift version (\d+)\.(\d+)", swift_version)
    require(match is not None and tuple(map(int, match.groups())) >= (6, 1), "xtool requires Swift 6.1 or newer")
    catalogs = sorted((toolchain / "usr/share/swift/SwiftConstantValues").glob("*.json"))
    require(bool(catalogs), "Selected toolchain has no SwiftConstantValues catalogs")
    protocols = set()
    for catalog in catalogs:
        data = json.loads(catalog.read_text())
        values = data.get("constValueProtocols") if isinstance(data, dict) else None
        require(isinstance(values, list) and all(isinstance(item, str) and item for item in values), f"Malformed protocol catalog {catalog}")
        protocols.update(values)
    metadata = workspace / "metadata"
    metadata.mkdir(exist_ok=True)
    protocols_file = metadata / "protocols.json"
    protocols_file.write_text(json.dumps(sorted(protocols)) + "\n")
    manifest = prepare(root, workspace, version, build_number, client_id, protocols_file)
    manifest["commands"] = identities["commands"] + manifest["commands"]
    manifest.update(swift_version=swift_version, toolchain_dir=str(toolchain))
    xcode_identity = command(manifest, ["xcodebuild", "-version"], "xtool-xcode-version")
    xcode_match = re.search(r"^Build version (\S+)$", xcode_identity, re.MULTILINE)
    require(xcode_match is not None, "Cannot determine actual Xcode build version")
    manifest["xcode_build"] = xcode_match.group(1)
    for platform, settings in manifest["platforms"].items():
        for field, option in (("sdk_path", "--show-sdk-path"), ("sdk_version", "--show-sdk-version"), ("sdk_build", "--show-sdk-build-version")):
            settings[field] = command(manifest, ["xcrun", "--sdk", platform, option], f"xtool-{platform}-{field}")
            require(bool(settings[field]), f"Missing {platform} {field}")
        require(Path(settings["sdk_path"]).is_dir(), f"Missing {platform} SDK")
        require(int(settings["sdk_version"].split(".")[0]) >= 26, "App Store submissions require platform SDK 26 or newer")
    tools = workspace / "tools"
    tools.mkdir(exist_ok=True)
    archive = tools / "xtool.app.zip"
    require(not (tools / "xtool.app").exists(), "Refusing unverified preexisting xtool installation")
    command(manifest, ["curl", "--fail", "--location", "--output", str(archive), XTOOL_URL], "xtool-download", timeout=600)
    require(digest(archive) == XTOOL_SHA256, "Pinned xtool archive SHA256 mismatch")
    command(manifest, ["ditto", "-x", "-k", str(archive), str(tools)], "xtool-extract", timeout=120)
    xtool = tools / "xtool.app/Contents/MacOS/xtool"
    require(xtool.is_file() and os.access(xtool, os.X_OK), "Pinned xtool executable missing")
    manifest["xtool"]["executable_sha256"] = digest(xtool)
    proxy = tools / "swiftpm-proxy"
    proxy.mkdir()
    for tool in ("build", "package"):
        script = proxy / f"swift-{tool}"
        script.write_text(f"#!{sys.executable}\nimport runpy, sys\nsys.path.insert(0, {str(Path(__file__).resolve().parent)!r})\n"
                          f"sys.argv = [{str(Path(__file__).resolve())!r}, '_proxy', {tool!r}, *sys.argv[1:]]\n"
                          f"runpy.run_path({str(Path(__file__).resolve())!r}, run_name='__main__')\n")
        script.chmod(0o755)
    for platform, arch in (("iphoneos", "arm64"), ("watchos", "arm64"), ("watchos", "arm64_32")):
        triple = f'{arch}-apple-{"watchos" if platform == "watchos" else "ios"}'
        package = workspace / "source" / platform
        components = [c for c in manifest["components"] if c["platform"] == platform]
        evidence = workspace / "intermediates" / triple
        evidence.mkdir(parents=True)
        config = {"swift": str(swift), "platform": platform, "triple": triple, "package": str(package), "components": components,
                  "minimum_os": PLATFORMS[platform]["architecture_minimum_os"][arch],
                  "dependency_dir": str(evidence), "recipe_path": str(evidence / "Package.swift"),
                  "commands_path": str(evidence / "swiftpm-commands.jsonl")}
        config_file = evidence / "proxy.json"
        config_file.write_text(json.dumps(config))
        environment = dict(os.environ, XTL_CLI="1", SWIFTPM_CUSTOM_BIN_DIR=str(proxy))
        environment["OTODO_XTOOL_PROXY_CONFIG"] = str(config_file)
        environment.pop("SDKROOT", None)
        command(manifest, [str(xtool), "dev", "build", "-c", "release", "--triple", triple],
                f"xtool-build-{triple}", cwd=package, env=environment, timeout=3600)
        packed = package / "xtool" / f'{components[0]["name"]}.app'
        require(packed.is_dir(), f"xtool did not pack {packed}")
        retained = workspace / "products" / triple / packed.name
        retained.parent.mkdir(parents=True)
        shutil.copytree(packed, retained, symlinks=True)
        bin_directory = package / ".build" / triple / "release"
        require(bin_directory.is_dir(), f"Missing native SwiftPM bin directory {bin_directory}")
        for component in components:
            name = component["name"]
            bundle = retained if not component["extension_point"] else retained / "PlugIns" / f"{name}.appex"
            binary = bundle / name
            wrapper = bin_directory / f'{name}-{"Extension" if component["extension_point"] else "App"}'
            dependency_info = evidence / f"{name}.dat"
            for required in (binary, wrapper, dependency_info):
                require(required.is_file() and required.stat().st_size > 0, f"Missing actual xtool build artifact {required}")
            require(digest(binary) == digest(wrapper), f"xtool packed a different executable for {name}")
            require((bundle / "OTodoCore_OTodoCore.bundle").is_dir(), f"Missing original Core resources in {bundle}")
            compiler_list = bin_directory / f"{name}.build/sources"
            require(compiler_list.is_file(), f"Missing compiler source list for {name}")
            compiled_sources = {str(Path(line).resolve()) for line in compiler_list.read_text().splitlines() if line}
            require(compiled_sources == set(component["source_files"]), f"{name}: compiler source membership differs from project.yml")
            const_values = []
            if name == "OTodo":
                const = metadata / "OTodo.swiftconstvalues"
                require(const.is_file() and const.stat().st_size > 0, "OTodo const-value extraction produced no sidecar")
                require(bool(json.loads(const.read_text())), "OTodo const-value sidecar is empty")
                const_values = [str(const)]
            component["slices"].append({"arch": arch, "triple": triple + config["minimum_os"],
                                        "binary": str(binary), "bundle": str(bundle), "build_directory": str(bin_directory),
                                        "dependency_info": str(dependency_info), "const_values": const_values,
                                        "binary_sha256": digest(binary)})
        manifest.setdefault("swiftpm_commands", []).extend(json.loads(line) for line in Path(config["commands_path"]).read_text().splitlines())
    for component in manifest["components"]:
        expected = {"arm64", "arm64_32"} if component["platform"] == "watchos" else {"arm64"}
        require({item["arch"] for item in component["slices"]} == expected, f"Incomplete slices for {component['name']}")
        for source in component["source_inputs"]:
            require(digest(Path(source["staged"])) == source["sha256"] == digest(root / source["source"]), "Source changed during compilation")
    require(digest(root / "Package.swift") == manifest["core_package"]["sha256"], "Core package changed during compilation")
    for source in manifest["core_package"]["source_inputs"]:
        require(digest(root / source["source"]) == source["sha256"], "Core source or resource changed during compilation")
    (workspace / "xtool-build.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main() -> None:
    if len(sys.argv) > 2 and sys.argv[1] == "_proxy":
        swiftpm_proxy(sys.argv[2], sys.argv[3:])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "build"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--version", default=os.environ.get("MARKETING_VERSION"), required=not os.environ.get("MARKETING_VERSION"))
    parser.add_argument("--build-number", default=os.environ.get("BUILD_NUMBER"), required=not os.environ.get("BUILD_NUMBER"))
    parser.add_argument("--client-id", default=os.environ.get("GITHUB_CLIENT_ID"), required=not os.environ.get("GITHUB_CLIENT_ID"))
    parser.add_argument("--protocols-file", type=Path)
    arguments = parser.parse_args()
    if arguments.action == "prepare":
        prepare(arguments.root, arguments.workspace, arguments.version, arguments.build_number, arguments.client_id, arguments.protocols_file)
    else:
        require(arguments.protocols_file is None, "build derives protocols from the selected Xcode toolchain")
        build(arguments.root, arguments.workspace, arguments.version, arguments.build_number, arguments.client_id)


if __name__ == "__main__":
    try:
        main()
    except (CommandError, ValueError, OSError) as error:
        annotate("error", str(error), title="xtool build")
        raise SystemExit(1)
