#!/usr/bin/env python3
"""Local Mac coverage: hosted/UI tests, signed bundles, and live/offline Watch."""

import json
import os
from pathlib import Path
import platform
import shutil
import sys
import tempfile

from command_runtime import CommandError, annotate, run_command
import ios_tests
from validate_bundles import validate_built
import watch_smoke


def remove_devices(devices):
    failures = []
    for identifier in devices:
        try:
            run_command(["xcrun", "simctl", "delete", identifier], stage="simulator-cleanup", timeout=60)
        except CommandError as error:
            failures.append(str(error))
    if failures:
        raise RuntimeError("Failed to remove test-owned simulators: " + "; ".join(failures))


def main():
    if platform.system() != "Darwin":
        raise RuntimeError("Apple tests require a local Mac; no simulator coverage ran")
    for tool in ("xcodebuild", "xcrun", "xcodegen"):
        if shutil.which(tool) is None:
            raise RuntimeError(f"Required local Apple test tool is missing: {tool}")
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    parent = root / ".build/local-tests"
    parent.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="apple-", dir=parent))
    print(f"Local Apple test evidence: {output}", flush=True)
    # Use the selected Xcode, including a caller-supplied DEVELOPER_DIR.
    run_command(["xcodebuild", "-version"], stage="xcode-version", timeout=60)
    run_command(["xcodegen", "generate", "--spec", "project.yml"], stage="project-generation", timeout=90)
    failures = []
    ios_output = output / "ios"
    os.environ["OTODO_TEST_RESULTS_DIR"] = str(ios_output)
    try:
        state = ios_tests.prepare(ios_output)
        ios_tests.run(ios_output, state)
    except (CommandError, OSError, ValueError, KeyError, RuntimeError) as error:
        failures.append(f"iOS: {error}")
        annotate("error", failures[-1])
    finally:
        state_path = ios_output / "simulator.json"
        if state_path.exists():
            try:
                remove_devices([json.loads(state_path.read_text())["id"]])
            except (CommandError, RuntimeError) as error:
                failures.append(str(error))

    watch_output = output / "watch"
    watch_output.mkdir()
    os.environ["OTODO_TEST_RESULTS_DIR"] = str(watch_output)
    try:
        watch_smoke.prepare(watch_output)
        derived_data = watch_output / "DerivedData"
        watch_smoke.build(watch_output, derived_data)
        validate_built(derived_data / "Build/Products/Debug-iphonesimulator/OTodo.app")
        watch_smoke.verify(watch_output, derived_data)
    except (CommandError, OSError, ValueError, KeyError, RuntimeError) as error:
        failures.append(f"Watch: {error}")
        annotate("error", failures[-1])
    finally:
        try:
            if not watch_smoke.diagnostics(watch_output):
                failures.append("Watch diagnostic collection was incomplete")
        except (CommandError, OSError, ValueError, KeyError, RuntimeError) as error:
            failures.append(f"Watch diagnostics: {error}")
        devices_path = watch_output / "devices.json"
        if devices_path.exists():
            try:
                remove_devices(json.loads(devices_path.read_text()).values())
            except (CommandError, RuntimeError) as error:
                failures.append(str(error))
    if failures:
        raise RuntimeError("Local Apple verification failed: " + "; ".join(failures))
    print(f"Local hosted/UI, bundle and live/offline Watch verification passed. Evidence: {output}")


if __name__ == "__main__":
    try:
        main()
    except (CommandError, OSError, ValueError, KeyError, RuntimeError) as error:
        annotate("error", str(error))
        sys.exit(error.returncode if isinstance(error, CommandError) else 1)
    except KeyboardInterrupt:
        sys.exit(130)
