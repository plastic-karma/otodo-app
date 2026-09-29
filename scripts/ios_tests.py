#!/usr/bin/env python3
"""Run all hosted and UI tests locally, retaining compiled coverage and results."""

from collections import Counter
import json
import os
from pathlib import Path

from command_runtime import CommandError, run_command
from validate_bundles import validate_built


def prepare(output):
    """Create a disposable iPhone without changing the user's existing devices."""
    output.mkdir(parents=True, exist_ok=True)
    inventory = json.loads(run_command(
        ["xcrun", "simctl", "list", "--json"], stage="ios-inventory", timeout=180, capture=True,
    ))
    runtimes = [item for item in inventory["runtimes"]
                if item.get("isAvailable") and ".SimRuntime.iOS-" in item["identifier"]]
    if not runtimes:
        raise ValueError("An installed available iOS simulator runtime is required")
    runtime = max(runtimes, key=lambda item: tuple(map(int, item["version"].split("."))))
    parts = (tuple(map(int, runtime["version"].split("."))) + (0, 0))[:3]
    encoded = (parts[0] << 16) | (parts[1] << 8) | parts[2]
    types = [item for item in inventory["devicetypes"] if item.get("productFamily") == "iPhone"
             and item.get("minRuntimeVersion", 0) <= encoded <= item.get("maxRuntimeVersion", 0xFFFFFFFF)]
    if not types:
        raise ValueError(f"No compatible iPhone device type for {runtime['name']}")
    device = max(types, key=lambda item: (item.get("minRuntimeVersion", 0), item["name"]))
    identifier = run_command(
        ["xcrun", "simctl", "create", "OTodo local tests", device["identifier"], runtime["identifier"]],
        stage="ios-create", timeout=60, capture=True,
    ).strip()
    state = {"id": identifier, "name": device["name"], "runtime": runtime["identifier"]}
    write_json(output / "simulator.json", state)
    return state


def verify_coverage(directory, expected):
    observed, unexpected = observed_cases(directory, "ios-tests", expected)
    missing = sorted(set(expected) - set(observed))
    unsuccessful = sorted(test for test, outcome in observed.items() if outcome != "passed")
    coverage = {"expected": expected, "observed": observed, "missing": missing,
                "unexpected": unexpected, "unsuccessful": unsuccessful}
    write_json(directory / "coverage.json", coverage)
    if missing or unexpected or unsuccessful:
        raise ValueError(f"Incomplete iOS coverage: missing={missing}, unexpected={unexpected}, not-passed={unsuccessful}")
    print(f"COVERAGE PASS: all {len(expected)} compiled hosted and UI tests passed", flush=True)


def run(output, state):
    derived_data = output / "DerivedData"
    packages = derived_data / "SourcePackages"
    packages.mkdir(parents=True, exist_ok=True)
    base = ["-project", "OTodo.xcodeproj", "-scheme", "OTodo", "-derivedDataPath", str(derived_data),
            "-clonedSourcePackagesDirPath", str(packages)]
    destination = ["-destination", f"platform=iOS Simulator,id={state['id']}", "-destination-timeout", "60"]
    run_command(["xcodebuild", "-resolvePackageDependencies", *base], stage="ios-packages", timeout=600,
                log_path=output / "packages.log")
    boot = run_command(["xcrun", "simctl", "bootstatus", state["id"], "-b"], stage="ios-boot", timeout=420,
                       capture=True, log_path=output / "boot.log")
    if not any(line.strip() == "Finished" for line in boot.splitlines()):
        raise ValueError("The iPhone simulator did not finish booting successfully; inspect boot.log")
    run_command([
        "xcodebuild", "build-for-testing", *base, *destination, "-disableAutomaticPackageResolution",
        "-resultBundlePath", str(output / "build.xcresult"), "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-",
        f"GITHUB_CLIENT_ID={os.environ.get('GITHUB_CLIENT_ID', os.environ.get('GH_OAUTH_CLIENT_ID', ''))}",
    ], stage="ios-build", timeout=1800, log_path=output / "build.log")
    products = derived_data / "Build/Products"
    validate_built(products / "Debug-iphonesimulator/OTodo.app")
    test_runs = list(products.glob("*.xctestrun"))
    if len(test_runs) != 1:
        raise ValueError(f"Expected one compiled .xctestrun, found {len(test_runs)}")
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(test_runs[0]), *destination,
               "-parallel-testing-enabled", "NO"]
    enumeration = output / "enumeration.json"
    run_command([*command, "-enumerate-tests", "-test-enumeration-style", "flat", "-test-enumeration-format", "json",
                 "-test-enumeration-output-path", str(enumeration)], stage="ios-enumeration", timeout=600,
                log_path=output / "enumeration.log")
    tests, disabled = enumerated_tests(json.loads(enumeration.read_text()))
    if disabled or not all(any(test.startswith(target + "/") for test in tests)
                           for target in ("OTodoAppTests", "OTodoUITests")):
        raise ValueError(f"Complete local coverage requires hosted and UI tests without disabled tests: {disabled}")
    result = output / "tests.xcresult"
    try:
        run_command([*command, "-resultBundlePath", str(result), "-test-timeouts-enabled", "YES",
                     "-default-test-execution-time-allowance", "360", "-maximum-test-execution-time-allowance", "600",
                     "-collect-test-diagnostics", "on-failure"], stage="ios-tests", timeout=14400,
                    startup_timeout=900, log_path=output / "tests.log")
    except CommandError:
        # Preserve the originating status, with coverage retained even after failure.
        observed, unexpected = observed_cases(output, "ios-tests", tests)
        write_json(output / "coverage.json", {"expected": tests, "observed": observed, "unexpected": unexpected})
        raise
    verify_coverage(output, tests)


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


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
