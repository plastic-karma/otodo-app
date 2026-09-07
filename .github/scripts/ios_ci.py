#!/usr/bin/env python3
"""Build once, gate early, and account for every compiled iOS test."""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import sys
import tarfile

from ci_runtime import CommandError, annotate, cancellation_scope, run_command

ROOT = Path(__file__).resolve().parents[2]
CRITICAL_TESTS = {
    "OTodoUITests/OTodoUITests/testAddAndEditTodo",
    "OTodoUITests/OTodoUITests/testAttachmentSelectionSavesOfflineAndClearsForAnotherTodo",
}
SYSTEM_TESTS = {
    "OTodoUITests/OTodoUITests/testHomeScreenQuickActionOpensNewTodoEditor",
    "OTodoUITests/OTodoUITests/testHomeScreenQuickActionReplacesOpenSiblingDraftWithRoot",
    "OTodoUITests/OTodoUITests/testTodayWidgetRendersInWidgetGallery",
}
GROUPS = ("smoke", "functional", "integration")
REQUIRED_JOBS = {"preflight", "swift-package-tests", "ios-build", "ios-tests", "watchos-simulator"}


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def output_values(values):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as output:
            for key, value in values.items():
                text = str(value)
                if "\n" in text or "\r" in text:
                    raise ValueError(f"Invalid multiline output: {key}")
                output.write(f"{key}={text}\n")


def configure(test_filter, diagnostics):
    if test_filter and not test_filter.strip():
        raise ValueError("test_filter cannot contain only whitespace")
    test_filter = test_filter.strip().removesuffix("()")
    if test_filter and not re.fullmatch(r"[A-Za-z_]\w*(?:/[A-Za-z_]\w*){0,2}", test_filter):
        raise ValueError("test_filter must be Target[/Class[/testMethod]], not shell flags or a wildcard")
    mode = "focused" if test_filter else "diagnostics" if diagnostics else "full"
    output_values({"mode": mode, "filter": test_filter})
    print(f"CI mode: {mode}; selected filter: {test_filter or 'none (all tests)'}", flush=True)
    return mode


def toolchain():
    return {
        "xcode": run_command(["xcodebuild", "-version"], stage="test-toolchain", timeout=60, capture=True).strip(),
        "architecture": platform.machine(),
        "sdk": run_command(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], stage="test-sdk", timeout=60, capture=True).strip(),
    }


def prepare(output, expected=None):
    output.mkdir(parents=True, exist_ok=True)
    identity = toolchain()
    if expected and identity != expected["toolchain"]:
        raise ValueError(f"Test products require {expected['toolchain']}; runner has {identity}")
    devices = json.loads(run_command(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        stage="ios-inventory", timeout=180, capture=True,
    ))["devices"]
    wanted = expected.get("simulator") if expected else None
    choices = []
    for runtime, items in devices.items():
        if ".iOS-" not in runtime or (wanted and runtime != wanted["runtime"]):
            continue
        for device in items:
            if not device.get("isAvailable") or not device.get("name", "").startswith("iPhone"):
                continue
            if wanted and device["name"] != wanted["name"]:
                continue
            version = tuple(int(part) for part in re.findall(r"\d+", runtime))
            choices.append((version, device["name"].endswith("Pro"), device["name"], runtime, device["udid"]))
    if not choices:
        raise ValueError(f"No compatible preinstalled iPhone simulator is available: {wanted or 'any iPhone'}")
    _, _, name, runtime, identifier = max(choices)
    state = {"id": identifier, "name": name, "runtime": runtime, "toolchain": identity}
    write_json(output / "simulator.json", state)
    print(f"Selected {name}, {runtime}, UUID {identifier}", flush=True)
    return state


def normalize_identifier(identifier):
    if not isinstance(identifier, str):
        raise ValueError("Compiled test identifier must be a string")
    identifier = identifier.removesuffix("()")
    parts = identifier.split("/")
    if len(parts) != 3 or any(not part or "\n" in part or "\r" in part for part in parts):
        raise ValueError(f"Unsupported compiled test identifier: {identifier!r}")
    if parts[1].startswith(parts[0] + "."):
        parts[1] = parts[1][len(parts[0]) + 1:]
    return "/".join(parts)


def enumerated_tests(enumeration):
    if not isinstance(enumeration, dict) or not isinstance(enumeration.get("values"), list):
        raise ValueError("Xcode returned an unsupported test enumeration document")
    if enumeration.get("errors"):
        raise ValueError(f"Xcode test enumeration failed: {enumeration['errors']}")
    enabled, disabled = [], []
    for configuration in enumeration["values"]:
        if not isinstance(configuration, dict) or not isinstance(configuration.get("enabledTests"), list):
            raise ValueError("Xcode enumeration is missing enabledTests")
        for test in configuration["enabledTests"]:
            enabled.append(normalize_identifier(test["identifier"]))
        for test in configuration.get("disabledTests", []):
            disabled.append(test["identifier"])
    if not enabled:
        raise ValueError("Xcode enumerated no enabled tests; empty coverage is not success")
    duplicates = [identifier for identifier, count in Counter(enabled).items() if count != 1]
    if duplicates:
        raise ValueError(f"Test configurations repeat identifiers; give each configuration an explicit plan: {duplicates}")
    return sorted(enabled), sorted(disabled)


def make_plan(tests, disabled, weights, *, mode, test_filter):
    if mode not in {"full", "diagnostics", "focused"}:
        raise ValueError(f"Unknown CI mode: {mode}")
    if mode == "focused":
        if not test_filter:
            raise ValueError("Focused mode requires a test filter")
        selected = [test for test in tests if test == test_filter or test.startswith(test_filter + "/")]
        if not selected:
            raise ValueError(f"No compiled tests match test_filter {test_filter!r}")
        return {"smoke": selected, "functional": [], "integration": []}
    if test_filter:
        raise ValueError("Full and complete-diagnostics modes must not restrict test_filter")
    if disabled:
        raise ValueError(f"Full verification cannot silently omit disabled compiled tests: {disabled}")
    required = CRITICAL_TESTS | SYSTEM_TESTS
    if not required.issubset(tests):
        raise ValueError(f"Required behavioral tests disappeared from the compiled scheme: {sorted(required - set(tests))}")
    hosted = [test for test in tests if test.startswith("OTodoAppTests/")]
    if not hosted:
        raise ValueError("The compiled scheme omitted hosted OTodoAppTests")
    groups = {"smoke": sorted(set(hosted) | CRITICAL_TESTS), "functional": [], "integration": sorted(SYSTEM_TESTS)}
    assigned = set(groups["smoke"]) | SYSTEM_TESTS
    loads = {"functional": 0.0, "integration": sum(weights.get(test, 60.0) for test in SYSTEM_TESTS)}
    for test in sorted(set(tests) - assigned, key=lambda value: (-weights.get(value, 60.0), value)):
        group = min(loads, key=lambda name: (loads[name], name))
        groups[group].append(test)
        loads[group] += weights.get(test, 60.0)
    for group in groups:
        groups[group].sort()
    planned = [test for selected in groups.values() for test in selected]
    if Counter(planned) != Counter(tests):
        raise ValueError("Partition planning lost or duplicated compiled tests")
    if not all(groups[group] for group in GROUPS):
        raise ValueError("Full verification requires nonempty smoke, functional and integration partitions")
    return groups


def build(output, derived_data):
    state = prepare(output)
    results = output / "results"
    results.mkdir(exist_ok=True)
    source_packages = derived_data / "SourcePackages"
    source_packages.mkdir(parents=True, exist_ok=True)
    run_command([
        "xcodebuild", "-resolvePackageDependencies", "-project", "OTodo.xcodeproj", "-scheme", "OTodo",
        "-derivedDataPath", str(derived_data), "-clonedSourcePackagesDirPath", str(source_packages),
    ], stage="ios-package-resolution", timeout=600, log_path=output / "logs/packages.log")
    arguments = [
        "xcodebuild", "build-for-testing", "-project", "OTodo.xcodeproj", "-scheme", "OTodo",
        "-destination", f"platform=iOS Simulator,id={state['id']}", "-destination-timeout", "60",
        "-derivedDataPath", str(derived_data), "-resultBundlePath", str(results / "build.xcresult"),
        "-clonedSourcePackagesDirPath", str(source_packages), "-disableAutomaticPackageResolution",
        "-showBuildTimingSummary", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-",
        f"GITHUB_CLIENT_ID={os.environ.get('GH_OAUTH_CLIENT_ID', '')}",
    ]
    with cancellation_scope() as cancelled:
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [
                pool.submit(run_command, ["xcrun", "simctl", "bootstatus", state["id"], "-b"],
                            stage="ios-boot", timeout=420, log_path=output / "logs/boot.log", cancel_event=cancelled),
                pool.submit(run_command, arguments, stage="ios-build", timeout=900,
                            log_path=output / "logs/build.log", cancel_event=cancelled),
            ]
            try:
                for future in as_completed(futures):
                    future.result()
            except BaseException:
                cancelled.set()
                raise
    products = derived_data / "Build/Products"
    run_command([
        sys.executable, str(ROOT / ".github/scripts/validate_bundles.py"), "built",
        "--app", str(products / "Debug-iphonesimulator/OTodo.app"), "--platform", "simulator",
    ], stage="ios-effective-bundle-validation", timeout=180)
    test_runs = list(products.glob("*.xctestrun"))
    if len(test_runs) != 1:
        raise ValueError(f"Expected one compiled .xctestrun, found {len(test_runs)}")
    enumeration_path = output / "enumeration.json"
    run_command([
        "xcodebuild", "test-without-building", "-xctestrun", str(test_runs[0]),
        "-destination", f"platform=iOS Simulator,id={state['id']}", "-destination-timeout", "60",
        "-parallel-testing-enabled", "NO", "-enumerate-tests", "-test-enumeration-style", "flat",
        "-test-enumeration-format", "json", "-test-enumeration-output-path", str(enumeration_path),
    ], stage="ios-compiled-test-inventory", timeout=600, log_path=output / "logs/enumeration.log")
    tests, disabled = enumerated_tests(json.loads(enumeration_path.read_text()))
    weights = json.loads((ROOT / ".github/ci-test-durations.json").read_text())["seconds"]
    mode, test_filter = os.environ.get("CI_MODE", "full"), os.environ.get("CI_FILTER", "")
    groups = make_plan(tests, disabled, weights, mode=mode, test_filter=test_filter)
    manifest = {
        "schema_version": 1, "sha": os.environ.get("GITHUB_SHA", "local"),
        "run_id": os.environ.get("GITHUB_RUN_ID", "local"), "mode": mode, "filter": test_filter,
        "toolchain": state["toolchain"], "simulator": {key: state[key] for key in ("name", "runtime")},
        "xctestrun": test_runs[0].name, "expected": sorted(test for values in groups.values() for test in values),
        "disabled": disabled, "groups": groups,
        "estimated_seconds": {group: round(sum(weights.get(test, 60.0) for test in values), 1) for group, values in groups.items()},
    }
    manifest["plan_id"] = hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest()
    write_json(output / "manifest.json", manifest)
    run_command([
        sys.executable, str(Path(__file__).resolve()), "pack", "--products", str(products),
        "--archive", str(output / "ios-test-products.tar.gz"),
    ], stage="ios-products-package", timeout=180)
    artifact = f"ios-test-products-{os.environ.get('GITHUB_RUN_ID', 'local')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    output_values({"build_ready": "true", "products_artifact": artifact})
    print(f"Compiled coverage: {len(manifest['expected'])} tests; partitions: {manifest['estimated_seconds']}", flush=True)


def load_manifest(path):
    manifest = json.loads(path.read_text())
    if manifest.get("schema_version") != 1:
        raise ValueError("Unsupported iOS product manifest version")
    for key, environment in (("sha", "GITHUB_SHA"), ("run_id", "GITHUB_RUN_ID")):
        if manifest.get(key) != os.environ.get(environment, "local"):
            raise ValueError(f"Test products belong to a different {key}; refusing cross-run coverage")
    if manifest.get("mode") != os.environ.get("CI_MODE", "full") or manifest.get("filter") != os.environ.get("CI_FILTER", ""):
        raise ValueError("Test products have a different full/diagnostic/focused mode")
    planned = [test for tests in manifest["groups"].values() for test in tests]
    if Counter(planned) != Counter(manifest["expected"]) or len(set(planned)) != len(planned):
        raise ValueError("Test product manifest has incomplete or duplicate partition coverage")
    if Path(manifest["xctestrun"]).name != manifest["xctestrun"]:
        raise ValueError("Invalid compiled test-run filename")
    return manifest


def pack_products(products, archive):
    def portable_member(member):
        # AppleDouble sidecars are filesystem metadata, not app resources.
        if PurePosixPath(member.name).name.startswith("._"):
            return None
        return member

    # Python does not synthesize libcopyfile's root ._Products entry on macOS.
    # Keep executable modes/internal links without copying host extended metadata.
    with tarfile.open(archive, "w:gz", compresslevel=1) as output:
        output.add(products, arcname="Products", filter=portable_member)


def unpack_products(archive, output):
    output.mkdir(parents=True, exist_ok=True)

    def product_member(member, destination):
        if member.name != "Products" and not member.name.startswith("Products/"):
            raise ValueError(f"Unexpected test product archive member: {member.name}")
        if ".." in PurePosixPath(member.name).parts:
            raise ValueError("Test product archive escapes its root")
        return tarfile.data_filter(member, destination)

    # One decompression pass; data_filter retains executable bits and safe
    # internal links while rejecting devices and links outside the destination.
    with tarfile.open(archive, "r:gz") as source:
        source.extractall(output, filter=product_member)


def restore(download, output):
    manifest = load_manifest(download / "manifest.json")
    state = prepare(output, manifest)
    run_command([
        sys.executable, str(Path(__file__).resolve()), "unpack",
        "--archive", str(download / "ios-test-products.tar.gz"), "--output", str(output),
    ], stage="ios-products-restore", timeout=180)
    write_json(output / "manifest.json", manifest)
    run_command([
        sys.executable, str(ROOT / ".github/scripts/validate_bundles.py"), "built",
        "--app", str(output / "Products/Debug-iphonesimulator/OTodo.app"), "--platform", "simulator",
    ], stage="ios-restored-bundle-validation", timeout=180)
    run_command(["xcrun", "simctl", "bootstatus", state["id"], "-b"],
                stage="ios-worker-boot", timeout=420, log_path=output / "logs/boot.log")


def observed_cases(metrics_directory, stage, expected):
    observed, unexpected = {}, set()
    for path in metrics_directory.glob("command-*.json"):
        metrics = json.loads(path.read_text())
        if metrics.get("stage") != stage:
            continue
        for case in metrics.get("test_cases", []):
            identifier = case["identifier"].removesuffix("()")
            if identifier not in expected:
                candidates = [test for test in expected if test.endswith("/" + identifier)]
                if len(candidates) == 1:
                    identifier = candidates[0]
                else:
                    unexpected.add(identifier)
                    continue
            # Native runners may repeat a result in a final summary. A later pass
            # must never hide a failed/skipped observation of that same case.
            status = case["status"]
            if identifier not in observed or status != "passed":
                observed[identifier] = status
    return observed, sorted(unexpected)


def run_group(output, group, products=None):
    manifest = load_manifest(output / "manifest.json")
    state = json.loads((output / "simulator.json").read_text())
    expected = manifest["groups"][group]
    if not expected:
        raise ValueError(f"No tests were planned for {group}; do not run an empty partition")
    products = products or output / "Products"
    result = output / "results" / f"{group}.xcresult"
    result.parent.mkdir(parents=True, exist_ok=True)
    stage = f"ios-tests-{group}"
    command = [
        "xcodebuild", "test-without-building", "-xctestrun", str(products / manifest["xctestrun"]),
        "-destination", f"platform=iOS Simulator,id={state['id']}", "-destination-timeout", "60",
        "-resultBundlePath", str(result), "-parallel-testing-enabled", "NO",
        "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "360",
        "-maximum-test-execution-time-allowance", "600", "-collect-test-diagnostics", "on-failure",
        *[f"-only-testing:{test}" for test in expected],
    ]
    status = 0
    try:
        run_command(command, stage=stage, timeout=1200 if group == "smoke" else 2700,
                    startup_timeout=900, log_path=output / "logs" / f"{group}.log")
    except CommandError as error:
        status = error.returncode
    metrics = Path(os.environ["CI_RESULTS_DIR"])
    observed, unexpected = observed_cases(metrics, stage, manifest["expected"])
    missing = sorted(set(expected) - set(observed))
    unexpected = sorted(set(unexpected) | (set(observed) - set(expected)))
    unsuccessful = sorted(test for test, outcome in observed.items() if outcome != "passed")
    coverage = {
        "schema_version": 1, "sha": manifest["sha"], "run_id": manifest["run_id"],
        "attempt": int(os.environ.get("GITHUB_RUN_ATTEMPT", "1")),
        "mode": manifest["mode"], "filter": manifest["filter"], "plan_id": manifest["plan_id"],
        "group": group, "expected": expected, "observed": observed,
        "missing": missing, "unexpected": unexpected, "unsuccessful": unsuccessful, "command_status": status,
    }
    write_json(output / f"coverage-{group}.json", coverage)
    if missing or unexpected or unsuccessful:
        annotate("error", f"{group} coverage incomplete: missing={missing}, unexpected={unexpected}, not-passed={unsuccessful}", title="iOS test coverage")
        status = status or 1
    if status:
        raise CommandError(stage, status)
    print(f"COVERAGE PASS: {group}: {len(expected)} compiled tests passed", flush=True)


def verify_evidence(directory, needs):
    failures = {job: needs.get(job, {}).get("result", "missing") for job in REQUIRED_JOBS if needs.get(job, {}).get("result") != "success"}
    if failures:
        raise ValueError(f"Full CI has unsuccessful or missing required jobs: {failures}")
    if os.environ.get("CI_MODE") != "full" or os.environ.get("CI_FILTER"):
        raise ValueError("Diagnostic or filtered runs cannot satisfy full verification")
    selected = {}
    for path in directory.rglob("coverage-*.json"):
        coverage = json.loads(path.read_text())
        group = coverage.get("group")
        if group not in GROUPS:
            raise ValueError(f"Unknown iOS coverage group: {group}")
        for key, environment in (("sha", "GITHUB_SHA"), ("run_id", "GITHUB_RUN_ID")):
            if coverage.get(key) != os.environ.get(environment, "local"):
                raise ValueError(f"Coverage belongs to a different {key}")
        if coverage.get("mode") != "full" or coverage.get("filter"):
            raise ValueError("Focused/diagnostic evidence cannot satisfy full coverage")
        current = selected.get(group)
        if current is None or coverage["attempt"] > current[0]["attempt"]:
            selected[group] = (coverage, path)
        elif coverage["attempt"] == current[0]["attempt"] and coverage != current[0]:
            raise ValueError(f"Conflicting {group} evidence for the same attempt")
    if set(selected) != set(GROUPS):
        raise ValueError(f"Missing iOS partition evidence: {sorted(set(GROUPS) - set(selected))}")
    manifest = load_manifest(selected["smoke"][1].parent / "manifest.json")
    all_observed = []
    for group, (coverage, _) in selected.items():
        if coverage.get("plan_id") != manifest["plan_id"] or coverage.get("expected") != manifest["groups"][group]:
            raise ValueError(f"{group} belongs to a different compiled test plan")
        if coverage["command_status"] or coverage["missing"] or coverage["unexpected"] or coverage["unsuccessful"]:
            raise ValueError(f"{group} did not finish with complete successful coverage")
        if set(coverage["observed"]) != set(coverage["expected"]) or any(value != "passed" for value in coverage["observed"].values()):
            raise ValueError(f"{group} test observations do not prove its expected coverage")
        all_observed.extend(coverage["observed"])
    if Counter(all_observed) != Counter(manifest["expected"]):
        raise ValueError("Full verification lost or duplicated tests between partitions")
    statement = f"FULL VERIFICATION PASSED: {len(all_observed)} compiled iOS tests, Linux core tests, and real live/offline Watch checks; SHA {manifest['sha']}"
    print(statement, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write("## Canonical full verification\n\n" + statement + "\n")
    return len(all_observed)


def diagnostics(output, export_snapshots):
    errors = []
    if export_snapshots:
        for result in sorted((output / "results").glob("*.xcresult")):
            if result.name == "build.xcresult":
                continue
            destination = output / "snapshots" / result.stem
            destination.mkdir(parents=True, exist_ok=True)
            try:
                run_command(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path", str(destination)],
                            stage=f"ios-attachments-{result.stem}", timeout=90)
            except CommandError as error:
                errors.append(str(error))
                annotate("warning", f"Partial screenshot evidence: {error}")
    write_json(output / "diagnostics.json", {"complete": not errors, "errors": errors})
    if errors:
        raise CommandError("ios-diagnostics", 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    configure_parser = commands.add_parser("configure")
    configure_parser.add_argument("--filter", default="")
    configure_parser.add_argument("--diagnostics", action="store_true")
    build_parser = commands.add_parser("build")
    build_parser.add_argument("--output", type=Path, required=True)
    build_parser.add_argument("--derived-data", type=Path, required=True)
    restore_parser = commands.add_parser("restore")
    restore_parser.add_argument("--download", type=Path, required=True)
    restore_parser.add_argument("--output", type=Path, required=True)
    pack_parser = commands.add_parser("pack")
    pack_parser.add_argument("--products", type=Path, required=True)
    pack_parser.add_argument("--archive", type=Path, required=True)
    unpack_parser = commands.add_parser("unpack")
    unpack_parser.add_argument("--archive", type=Path, required=True)
    unpack_parser.add_argument("--output", type=Path, required=True)
    tests_parser = commands.add_parser("test")
    tests_parser.add_argument("--output", type=Path, required=True)
    tests_parser.add_argument("--group", choices=GROUPS, required=True)
    tests_parser.add_argument("--products", type=Path)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--evidence", type=Path, required=True)
    diagnostics_parser = commands.add_parser("diagnostics")
    diagnostics_parser.add_argument("--output", type=Path, required=True)
    diagnostics_parser.add_argument("--export-snapshots", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "configure":
            configure(args.filter, args.diagnostics)
        elif args.command == "build":
            build(args.output, args.derived_data)
        elif args.command == "restore":
            restore(args.download, args.output)
        elif args.command == "pack":
            pack_products(args.products, args.archive)
        elif args.command == "unpack":
            unpack_products(args.archive, args.output)
        elif args.command == "test":
            run_group(args.output, args.group, args.products)
        elif args.command == "verify":
            verify_evidence(args.evidence, json.loads(os.environ["NEEDS_RESULTS"]))
        elif args.command == "diagnostics":
            diagnostics(args.output, args.export_snapshots)
    except CommandError as error:
        return error.returncode
    except (KeyError, OSError, TypeError, ValueError, tarfile.TarError) as error:
        annotate("error", str(error), title="iOS verification")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
