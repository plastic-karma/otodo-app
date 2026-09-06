#!/usr/bin/env python3
"""Exercise the real companion bridge and cached Watch launch on paired simulators."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import time


PHONE_BUNDLE = "plastickarma.otodo"
WATCH_BUNDLE = "plastickarma.otodo.watchkitapp"
APP_GROUP = "group.plastickarma.otodo"
EXPECTED_NAMES = {"Seed todo", "Overdue todo", "Future todo", "Week review", "Later review"}


def run(*arguments, capture=False):
    print("+ " + shlex.join(str(value) for value in arguments), flush=True)
    result = subprocess.run(
        [str(value) for value in arguments], check=True, text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else None


def simulator_state():
    return json.loads(run("xcrun", "simctl", "list", "--json", capture=True))


def version(value):
    return tuple(int(part) for part in value.split("."))


def newest_runtime(state, platform):
    choices = [
        item for item in state["runtimes"]
        if item.get("isAvailable") and f".SimRuntime.{platform}-" in item["identifier"]
    ]
    return max(choices, key=lambda item: version(item["version"]), default=None)


def create_device(state, runtime, family, name):
    parts = (version(runtime["version"]) + (0, 0))[:3]
    encoded_version = (parts[0] << 16) | (parts[1] << 8) | parts[2]
    choices = [
        item for item in state["devicetypes"]
        if item.get("productFamily") == family
        and item.get("minRuntimeVersion", 0) <= encoded_version <= item.get("maxRuntimeVersion", 0xFFFFFFFF)
    ]
    if not choices:
        raise RuntimeError(f"No compatible {family} device type for {runtime['name']}")
    device_type = max(choices, key=lambda item: (item.get("minRuntimeVersion", 0), item["name"]))
    return run("xcrun", "simctl", "create", name, device_type["identifier"], runtime["identifier"], capture=True)


def prepare(output):
    state = simulator_state()
    watch_runtime = newest_runtime(state, "watchOS")
    if watch_runtime is None:
        run("xcodebuild", "-downloadPlatform", "watchOS")
        state = simulator_state()
        watch_runtime = newest_runtime(state, "watchOS")
    if watch_runtime is None:
        raise RuntimeError("A watchOS simulator runtime is required for companion verification")
    phone_runtime = newest_runtime(state, "iOS")
    watch_version = version(watch_runtime["version"])
    minimum_phone_version = (
        watch_version[0] if watch_version[0] >= 26 else watch_version[0] + 7,
        *watch_version[1:],
    )
    if phone_runtime is None or version(phone_runtime["version"]) < minimum_phone_version:
        run("xcodebuild", "-downloadPlatform", "iOS")
        state = simulator_state()
        phone_runtime = newest_runtime(state, "iOS")
    if phone_runtime is None or version(phone_runtime["version"]) < minimum_phone_version:
        raise RuntimeError("A compatible iPhone simulator runtime is required for companion verification")

    phone = create_device(state, phone_runtime, "iPhone", "OTodo companion smoke iPhone")
    watch = create_device(state, watch_runtime, "Apple Watch", "OTodo companion smoke Watch")
    devices = {"phone": phone, "watch": watch}
    (output / "devices.json").write_text(json.dumps(devices, indent=2))
    run("xcrun", "simctl", "pair", watch, phone)
    for device in (phone, watch):
        run("xcrun", "simctl", "bootstatus", device, "-b")
    with open(os.environ["GITHUB_ENV"], "a") as environment:
        environment.write(f"WATCH_PHONE_SIMULATOR_ID={phone}\nWATCH_SIMULATOR_ID={watch}\n")
    print(f"Prepared {phone_runtime['name']} with {watch_runtime['name']}")


def group_directory(device, bundle):
    return Path(run("xcrun", "simctl", "get_app_container", device, bundle, APP_GROUP, capture=True))


def wait_for_snapshot(path, expected=None, pid=None):
    # Cold paired simulators can take over three minutes to deliver the first reply.
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        if pid is not None:
            os.kill(pid, 0)
        try:
            value = json.loads(path.read_text())
        except FileNotFoundError:
            time.sleep(1)
            continue
        if value.get("version") != 1:
            raise RuntimeError(f"Unexpected companion protocol in {path}")
        names = {task["name"] for task in value["snapshot"]["tasks"]}
        if value["workspaceAvailable"] and names == EXPECTED_NAMES and (expected is None or value == expected):
            return value
        time.sleep(1)
    raise RuntimeError(f"The live companion snapshot did not arrive at {path}")


def launch(device, bundle, *arguments):
    result = run("xcrun", "simctl", "launch", "--terminate-running-process", device, bundle, *arguments, capture=True)
    print(result, flush=True)
    return int(result.rsplit(":", 1)[1].strip())


def screenshot(device, pid, path):
    time.sleep(3)
    os.kill(pid, 0)
    run("xcrun", "simctl", "io", device, "screenshot", path)


def verify(output, derived_data):
    devices = json.loads((output / "devices.json").read_text())
    phone, watch = devices["phone"], devices["watch"]
    phone_app = derived_data / "Build/Products/Debug-iphonesimulator/OTodo.app"
    watch_app = phone_app / "Watch/OTodoWatch.app"
    widget = watch_app / "PlugIns/OTodoWatchWidget.appex"
    for bundle, expected_id in ((phone_app, PHONE_BUNDLE), (watch_app, WATCH_BUNDLE), (widget, WATCH_BUNDLE + ".widget")):
        with open(bundle / "Info.plist", "rb") as source:
            info = plistlib.load(source)
        if info["CFBundleIdentifier"] != expected_id or not (bundle / info["CFBundleExecutable"]).is_file():
            raise RuntimeError(f"Missing executable or incorrect identity in {bundle}")
        shutil.copy2(bundle / "Info.plist", output / f"{expected_id}-Info.plist")

    run("xcrun", "simctl", "install", phone, phone_app)
    run("xcrun", "simctl", "install", watch, watch_app)
    launch(phone, PHONE_BUNDLE, "-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-upcoming")
    phone_cache = group_directory(phone, PHONE_BUNDLE) / "ui-testing/watch-snapshot/snapshot.json"
    phone_snapshot = wait_for_snapshot(phone_cache)
    by_name = {task["name"]: task for task in phone_snapshot["snapshot"]["tasks"]}
    if by_name["Future todo"]["dueTime"] != "09:15" or by_name["Week review"]["dueTime"] != "16:45":
        raise RuntimeError("The companion snapshot lost exact due times")

    watch_pid = launch(watch, WATCH_BUNDLE)
    screenshot(watch, watch_pid, output / "watch-initial-launch.png")
    watch_cache = group_directory(watch, WATCH_BUNDLE) / "workspace-data/watch-snapshot/snapshot.json"
    received = wait_for_snapshot(watch_cache, expected=phone_snapshot, pid=watch_pid)
    screenshot(watch, watch_pid, output / "watch-live-today-overdue.png")
    print("SMOKE PASS: real WCSession delivery retained all active dated tasks, future dates, and exact times", flush=True)

    # Shutting down the phone prevents a refresh request from waking its app;
    # the restarted Watch must use only its atomically persisted local snapshot.
    run("xcrun", "simctl", "shutdown", phone)
    watch_pid = launch(watch, WATCH_BUNDLE)
    run("xcrun", "simctl", "openurl", watch, "otodo-watch://today")
    if json.loads(watch_cache.read_text()) != received:
        raise RuntimeError("The Watch lost its cached snapshot while the phone was unavailable")
    screenshot(watch, watch_pid, output / "watch-offline-relaunch.png")
    print("SMOKE PASS: Watch relaunch and complication deep link work with the phone shut down", flush=True)
    (output / "result.json").write_text(json.dumps({
        "liveConnectivity": "passed",
        "offlineRelaunch": "passed",
        "deepLink": "passed",
        "activeDatedTaskNames": sorted(EXPECTED_NAMES),
        "physicalDeviceChecks": ["WCSession large-file delivery", "expedited complication updates", "watch-face placement"],
    }, indent=2))


def diagnostics(output):
    devices_path = output / "devices.json"
    if not devices_path.exists():
        return
    for role, device in json.loads(devices_path.read_text()).items():
        with open(output / f"{role}-watch-sync.log", "w") as log:
            subprocess.run([
                "xcrun", "simctl", "spawn", device, "log", "show", "--last", "10m", "--style", "compact", "--info", "--debug",
                "--predicate", 'process == "OTodo" OR process == "OTodoWatch" OR process == "wcd" OR subsystem BEGINSWITH "plastickarma.otodo" OR subsystem == "com.apple.WatchConnectivity"',
            ], stdout=log, stderr=subprocess.STDOUT, check=False, text=True)
        subprocess.run(["xcrun", "simctl", "io", device, "screenshot", str(output / f"{role}-final.png")], check=False)
    reports = Path.home() / "Library/Logs/DiagnosticReports"
    for report in reports.glob("OTodoWatch*"):
        if report.is_file():
            shutil.copy2(report, output / report.name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("prepare", "verify", "diagnostics"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path)
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=True)
    if arguments.mode == "prepare":
        prepare(arguments.output)
    elif arguments.mode == "verify":
        if arguments.derived_data is None:
            parser.error("verify requires --derived-data")
        verify(arguments.output, arguments.derived_data)
    else:
        diagnostics(arguments.output)


if __name__ == "__main__":
    main()
