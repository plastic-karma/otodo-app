#!/usr/bin/env python3
"""Exercise real companion delivery and cached Watch launch on paired simulators."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
import threading
import time

from ci_runtime import CommandError, annotate, cancellation_scope, run_command


PHONE_BUNDLE = "plastickarma.otodo"
WATCH_BUNDLE = "plastickarma.otodo.watchkitapp"
APP_GROUP = "group.plastickarma.otodo"
EXPECTED_NAMES = {"Seed todo", "Overdue todo", "Future todo", "Week review", "Later review"}
SMOKE_ARGUMENT = "-watch-smoke-diagnostics"
LOG_PREDICATE = ('process == "OTodo" OR process == "OTodoWatch" OR process == "wcd" '
                 'OR subsystem BEGINSWITH "plastickarma.otodo" '
                 'OR subsystem == "com.apple.WatchConnectivity"')


def run(*arguments, stage, timeout=60, capture=False, **options):
    return run_command([str(value) for value in arguments], stage=f"watch-{stage}",
                       timeout=timeout, capture=capture, **options).strip()


def save_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def progress(output, stage, **details):
    value = {"stage": stage, "at": datetime.now(timezone.utc).isoformat(), **details}
    print("WATCH PROGRESS " + json.dumps(value), flush=True)
    with (output / "progress.jsonl").open("a") as stream:
        stream.write(json.dumps(value) + "\n")


def simulator_state():
    return json.loads(run("xcrun", "simctl", "list", "--json", stage="inventory", timeout=180, capture=True))


def version(value):
    return tuple(int(part) for part in value.split("."))


def newest_runtime(state, platform):
    choices = [item for item in state["runtimes"]
               if item.get("isAvailable") and f".SimRuntime.{platform}-" in item["identifier"]]
    return max(choices, key=lambda item: version(item["version"]), default=None)


def create_device(state, runtime, family, name):
    parts = (version(runtime["version"]) + (0, 0))[:3]
    encoded_version = (parts[0] << 16) | (parts[1] << 8) | parts[2]
    choices = [item for item in state["devicetypes"]
               if item.get("productFamily") == family
               and item.get("minRuntimeVersion", 0) <= encoded_version <= item.get("maxRuntimeVersion", 0xFFFFFFFF)]
    if not choices:
        raise RuntimeError(f"No compatible {family} device type for {runtime['name']}")
    device_type = max(choices, key=lambda item: (item.get("minRuntimeVersion", 0), item["name"]))
    return run("xcrun", "simctl", "create", name, device_type["identifier"], runtime["identifier"],
               stage=f"create-{family.replace(' ', '-').lower()}", capture=True)


def prepare(output):
    state = simulator_state()
    save_json(output / "runtime-inventory.json", state)
    watch_runtime = newest_runtime(state, "watchOS")
    if watch_runtime is None:
        raise RuntimeError("A preinstalled available watchOS simulator runtime is required; no platform downloads are performed")
    phone_runtime = newest_runtime(state, "iOS")
    watch_version = version(watch_runtime["version"])
    minimum_phone_version = (watch_version[0] if watch_version[0] >= 26 else watch_version[0] + 7,
                             *watch_version[1:])
    if phone_runtime is None or version(phone_runtime["version"]) < minimum_phone_version:
        raise RuntimeError(f"A preinstalled iOS runtime compatible with {watch_runtime['name']} is required "
                           f"(minimum {'.'.join(map(str, minimum_phone_version))})")
    progress(output, "runtimes-selected", phone=phone_runtime["name"], watch=watch_runtime["name"],
             phoneVersion=phone_runtime["version"], watchVersion=watch_runtime["version"])
    phone = create_device(state, phone_runtime, "iPhone", "OTodo companion smoke iPhone")
    # Retain partial preparation evidence even if Watch creation/pairing fails.
    save_json(output / "devices.json", {"phone": phone})
    watch = create_device(state, watch_runtime, "Apple Watch", "OTodo companion smoke Watch")
    save_json(output / "devices.json", {"phone": phone, "watch": watch})
    run("xcrun", "simctl", "pair", watch, phone, stage="pair")
    if os.environ.get("GITHUB_ENV"):
        with open(os.environ["GITHUB_ENV"], "a") as environment:
            environment.write(f"WATCH_PHONE_SIMULATOR_ID={phone}\nWATCH_SIMULATOR_ID={watch}\n")
    progress(output, "paired", phone=phone, watch=watch, boots="deferred-to-build")


def build(output, derived_data):
    devices = json.loads((output / "devices.json").read_text())
    boot_devices = [(role, devices[role]) for role in ("phone", "watch")]
    source_packages = derived_data / "SourcePackages"
    source_packages.mkdir(parents=True, exist_ok=True)
    run("xcodebuild", "-resolvePackageDependencies", "-project", os.environ.get("PROJECT", "OTodo.xcodeproj"),
        "-scheme", "OTodo", "-derivedDataPath", derived_data,
        "-clonedSourcePackagesDirPath", source_packages,
        stage="package-resolution", timeout=600, log_path=output / "packages.log")
    cancelled = threading.Event()
    failures = []
    lock = threading.Lock()
    started = time.monotonic()

    def checked(*arguments, **options):
        try:
            return run(*arguments, cancel_event=cancelled, **options)
        except BaseException as error:
            with lock:
                failures.append(error)
            cancelled.set()
            raise

    progress(output, "build-and-boots-started")
    # The build remains on the main thread so the shared runner's signal handler
    # can cancel all active process groups. Every worker shares cancellation and
    # is joined even when another worker, the build, or the caller fails.
    with cancellation_scope(cancelled), ThreadPoolExecutor(max_workers=2, thread_name_prefix="watch-boot") as executor:
        boots = []
        try:
            for role, device in boot_devices:
                boots.append(executor.submit(checked, "xcrun", "simctl", "bootstatus", device, "-b",
                                             stage=f"boot-{role}", timeout=420,
                                             log_path=output / f"boot-{role}.log"))
            checked("xcodebuild", "build", "-project", os.environ.get("PROJECT", "OTodo.xcodeproj"),
                    "-scheme", "OTodo", "-destination", f"platform=iOS Simulator,id={devices['phone']}",
                    "-showBuildTimingSummary",
                    "-derivedDataPath", derived_data, "CODE_SIGNING_ALLOWED=YES", "CODE_SIGN_IDENTITY=-",
                    "-clonedSourcePackagesDirPath", source_packages, "-disableAutomaticPackageResolution",
                    f"GITHUB_CLIENT_ID={os.environ.get('GH_OAUTH_CLIENT_ID', '')}",
                    stage="full-app-build", timeout=900, log_path=output / "build.log")
            for boot in boots:
                boot.result()
        except BaseException:
            cancelled.set()
            for boot in boots:
                try:
                    boot.result()
                except BaseException:
                    pass  # First observed failure is retained below, not replaced by cancellation.
            if failures:
                raise failures[0]
            raise
        finally:
            elapsed = round(time.monotonic() - started, 3)
            progress(output, "build-and-boots-finished", elapsedSeconds=elapsed,
                     outcome="failed" if cancelled.is_set() else "passed")
    print(f"Watch full build + bounded paired boots wall time: {elapsed:.3f}s; "
          "individual command durations are in CI_RESULTS_DIR. Overlap benefit is unmeasured.", flush=True)


def group_directory(device, bundle, role):
    return Path(run("xcrun", "simctl", "get_app_container", device, bundle, APP_GROUP,
                    stage=f"{role}-app-group", capture=True))


def assert_running(pids):
    for role, pid in pids.items():
        try:
            os.kill(pid, 0)
        except ProcessLookupError as error:
            raise RuntimeError(f"The {role} app process {pid} exited during companion verification") from error


def observe_states(output, states, pids, observed):
    assert_running(pids)
    for role, path in states.items():
        try:
            state = json.loads(path.read_text())
        except FileNotFoundError:
            continue
        # Do not accept state left by the previous process after offline relaunch.
        if state.get("pid") != str(pids[role]):
            continue
        if state != observed.get(role):
            observed[role] = state
            progress(output, f"{role}-app-state", state=state)
        if state.get("terminalError"):
            raise RuntimeError(f"{role} app: {state['terminalError']}")


def wait_for_snapshot(path, *, output, states, pids, expected=None):
    # Absolute budget, never reset by transient readiness or partial progress.
    # Cold paired simulators can take over three minutes for their first reply.
    started = time.monotonic()
    deadline = started + 300
    progress(output, "snapshot-wait-started", source=str(path), timeoutSeconds=300)
    observed = {}
    last_snapshot = None
    while time.monotonic() < deadline:
        observe_states(output, states, pids, observed)
        try:
            value = json.loads(path.read_text())
        except FileNotFoundError:
            time.sleep(1)
            continue
        if value.get("version") != 1:
            raise RuntimeError(f"Unexpected companion protocol {value.get('version')!r} in {path}; expected version 1")
        names = {task["name"] for task in value["snapshot"]["tasks"]}
        summary = {"version": value["version"], "workspaceAvailable": value["workspaceAvailable"],
                   "names": sorted(names), "matchesPhone": expected is None or value == expected}
        if summary != last_snapshot:
            last_snapshot = summary
            progress(output, "snapshot-observed", snapshot=summary)
        if value["workspaceAvailable"] and names == EXPECTED_NAMES and (expected is None or value == expected):
            progress(output, "snapshot-delivered", source=str(path),
                     elapsedSeconds=round(time.monotonic() - started, 3))
            return value
        time.sleep(1)
    raise RuntimeError(f"The live companion snapshot did not arrive within 300s at {path}; "
                       f"expected names: {sorted(EXPECTED_NAMES)}; observed snapshot: {json.dumps(last_snapshot)}; "
                       f"last app-owned state: {json.dumps(observed)}")


def launch(device, bundle, role, *arguments):
    result = run("xcrun", "simctl", "launch", "--terminate-running-process", device, bundle,
                 SMOKE_ARGUMENT, *arguments, stage=f"launch-{role}", capture=True)
    print(result, flush=True)
    return int(result.rsplit(":", 1)[1].strip())


def screenshot(device, pids, path, role):
    time.sleep(3)
    assert_running(pids)
    run("xcrun", "simctl", "io", device, "screenshot", path, stage=f"screenshot-{role}", timeout=30)
    assert_running(pids)


def collect_role(output, role, device, phase, failures):
    # Each attempt owns its log. Only successful collection replaces the canonical
    # file; a later shut-down simulator can never clobber valid phone evidence.
    attempt = f"{role}-{phase}-{time.time_ns()}"
    log = output / f"{attempt}.log"
    try:
        run("xcrun", "simctl", "spawn", device, "log", "show", "--last", "10m", "--style", "compact",
            "--info", "--debug", "--predicate", LOG_PREDICATE,
            stage=f"diagnostics-{role}-{phase}", timeout=45, log_path=log)
        shutil.copy2(log, output / f"{role}-watch-sync.log")
    except (CommandError, OSError, RuntimeError) as error:
        failures.append({"stage": f"{role}-{phase}-logs", "error": str(error)})
    try:
        run("xcrun", "simctl", "io", device, "screenshot", output / f"{attempt}.png",
            stage=f"diagnostics-{role}-screenshot", timeout=30)
    except (CommandError, OSError, RuntimeError) as error:
        failures.append({"stage": f"{role}-{phase}-screenshot", "error": str(error)})


def record_diagnostics(output, failures):
    path = output / "diagnostics-status.json"
    previous = json.loads(path.read_text()) if path.exists() else {"failures": []}
    previous["failures"].extend(failures)
    previous["complete"] = not previous["failures"]
    save_json(path, previous)
    for failure in failures:
        annotate("warning", f"Incomplete Watch evidence ({failure['stage']}): {failure['error']}")
    return previous["complete"]


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

    run("xcrun", "simctl", "install", phone, phone_app, stage="install-phone", timeout=120)
    run("xcrun", "simctl", "install", watch, watch_app, stage="install-watch", timeout=120)
    progress(output, "apps-installed")
    phone_pid = launch(phone, PHONE_BUNDLE, "phone", "-ui-testing", "-ui-testing-reset-workspace", "-ui-testing-upcoming")
    pids = {"phone": phone_pid}
    save_json(output / "processes.json", pids)
    phone_cache = group_directory(phone, PHONE_BUNDLE, "phone") / "ui-testing/watch-snapshot/snapshot.json"
    states = {"phone": phone_cache.with_name("smoke-state.json")}
    evidence = {"phone": str(phone_cache)}
    save_json(output / "evidence-paths.json", evidence)
    phone_snapshot = wait_for_snapshot(phone_cache, output=output, states=states, pids=pids)
    by_name = {task["name"]: task for task in phone_snapshot["snapshot"]["tasks"]}
    if by_name["Future todo"]["dueTime"] != "09:15" or by_name["Week review"]["dueTime"] != "16:45":
        raise RuntimeError("The companion snapshot lost exact due times")

    pids["watch"] = launch(watch, WATCH_BUNDLE, "watch-live")
    save_json(output / "processes.json", pids)
    watch_cache = group_directory(watch, WATCH_BUNDLE, "watch") / "workspace-data/watch-snapshot/snapshot.json"
    states["watch"] = watch_cache.with_name("smoke-state.json")
    evidence["watch"] = str(watch_cache)
    save_json(output / "evidence-paths.json", evidence)
    screenshot(watch, pids, output / "watch-initial-launch.png", "watch-initial")
    received = wait_for_snapshot(watch_cache, expected=phone_snapshot, output=output, states=states, pids=pids)
    screenshot(watch, pids, output / "watch-live-today-overdue.png", "watch-live")
    observe_states(output, states, pids, {})
    progress(output, "live-connectivity-passed")
    print("SMOKE PASS: real WCSession delivery retained all active dated tasks, future dates, and exact times", flush=True)

    failures = []
    collect_role(output, "phone", phone, "pre-shutdown", failures)
    record_diagnostics(output, failures)
    # Shut down the phone so foreground refresh cannot wake it. The new Watch
    # process must demonstrate a real cache load, not merely leave a file behind.
    run("xcrun", "simctl", "shutdown", phone, stage="shutdown-phone")
    save_json(output / "phone-shutdown.json", {"shutdown": True, "pid": phone_pid})
    pids = {"watch": launch(watch, WATCH_BUNDLE, "watch-offline")}
    save_json(output / "processes.json", {"phone": phone_pid, "watch": pids["watch"], "phoneShutdown": True})
    offline_states = {"watch": states["watch"]}
    observed = {}
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        observe_states(output, offline_states, pids, observed)
        if observed.get("watch", {}).get("cache") == "loaded":
            break
        time.sleep(0.5)
    else:
        raise RuntimeError("The relaunched Watch did not report reading its cached snapshot within 30s")
    if json.loads(watch_cache.read_text()) != received:
        raise RuntimeError("The Watch lost its cached snapshot while the phone was unavailable")
    screenshot(watch, pids, output / "watch-offline-relaunch.png", "watch-offline")
    observe_states(output, offline_states, pids, observed)
    progress(output, "offline-relaunch-passed")
    print("SMOKE PASS: Watch relaunch retains its saved todos with the phone shut down", flush=True)
    save_json(output / "result.json", {
        "liveConnectivity": "passed", "offlineRelaunch": "passed",
        "activeDatedTaskNames": sorted(EXPECTED_NAMES),
        "physicalDeviceChecks": ["WCSession large-file delivery", "expedited complication updates", "watch-face placement and complication tap routing"],
    })


def diagnostics(output):
    failures = []
    devices_path = output / "devices.json"
    if not devices_path.exists():
        failures.append({"stage": "devices", "error": "Device preparation did not produce devices.json"})
    else:
        for role, device in json.loads(devices_path.read_text()).items():
            if role == "phone" and (output / "phone-shutdown.json").exists():
                if not (output / "phone-watch-sync.log").exists():
                    failures.append({"stage": "phone-logs", "error": "Phone shut down without a complete pre-shutdown log"})
                continue
            collect_role(output, role, device, "final", failures)
    evidence_path = output / "evidence-paths.json"
    if evidence_path.exists():
        for role, snapshot in json.loads(evidence_path.read_text()).items():
            for name, path in (("snapshot", Path(snapshot)), ("state", Path(snapshot).with_name("smoke-state.json"))):
                try:
                    shutil.copy2(path, output / f"{role}-{name}.json")
                except OSError as error:
                    failures.append({"stage": f"{role}-{name}", "error": str(error)})
    reports = Path.home() / "Library/Logs/DiagnosticReports"
    for pattern in ("OTodo-*", "OTodoWatch*"):
        for report in reports.glob(pattern):
            try:
                if report.is_file() and report.stat().st_mtime >= time.time() - 3600:
                    shutil.copy2(report, output / report.name)
            except OSError as error:
                failures.append({"stage": "crash-report", "error": str(error)})
    return record_diagnostics(output, failures)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("prepare", "build", "verify", "diagnostics"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path)
    arguments = parser.parse_args()
    if arguments.mode in ("build", "verify") and arguments.derived_data is None:
        parser.error(f"{arguments.mode} requires --derived-data")
    arguments.output.mkdir(parents=True, exist_ok=True)
    try:
        if arguments.mode == "prepare":
            prepare(arguments.output)
        elif arguments.mode == "build":
            build(arguments.output, arguments.derived_data)
        elif arguments.mode == "verify":
            verify(arguments.output, arguments.derived_data)
        else:
            if not diagnostics(arguments.output):
                return 1
    except (CommandError, OSError, ValueError, KeyError, RuntimeError) as error:
        annotate("error", f"Watch {arguments.mode} failed: {error}")
        save_json(arguments.output / f"{arguments.mode}-failure.json", {"error": str(error)})
        # Evidence collection is separate and best-effort: never replace the
        # originating command/assertion failure with a diagnostics failure.
        return error.returncode if isinstance(error, CommandError) else 1
    except KeyboardInterrupt:
        annotate("error", f"Watch {arguments.mode} cancelled")
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
