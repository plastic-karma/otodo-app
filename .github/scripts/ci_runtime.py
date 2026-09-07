#!/usr/bin/env python3
"""Bounded CI commands, live native diagnostics, and per-command evidence."""

import argparse
import codecs
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid


class CommandError(RuntimeError):
    def __init__(self, stage, returncode):
        self.stage = stage
        self.returncode = returncode
        super().__init__(f"{stage} exited with status {returncode}")


def _escape(value, *, property=False):
    value = str(value).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return value.replace(":", "%3A").replace(",", "%2C") if property else value


def _source_path(file, cwd=None):
    if file is None:
        return None
    path = Path(file)
    root = Path(os.environ.get("GITHUB_WORKSPACE", Path.cwd())).resolve()
    absolute = (Path(cwd or root) / path).resolve()
    try:
        return str(absolute.relative_to(root))
    except ValueError:
        return str(absolute)


def annotate(level, message, *, file=None, line=None, title=None):
    if level not in {"warning", "error", "notice"}:
        raise ValueError("annotation level must be warning, error, or notice")
    properties = {"file": _source_path(file), "line": line, "title": title}
    fields = ",".join(f"{key}={_escape(value, property=True)}" for key, value in properties.items() if value is not None)
    print(f"::{level}{' ' + fields if fields else ''}::{_escape(message)}", file=sys.stderr, flush=True)


_ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
_SOURCE_ERROR = re.compile(r"^(.+?):(\d+)(?::\d+)?:\s*(?:fatal )?error:\s*(.*)$")
_TOOL_ERROR = re.compile(r"^(?:error|fatal error|(?:xcodebuild|swiftc|clang|ld|codesign)(?:[^:\n]*)?: (?:fatal )?error):\s*(.+)$", re.IGNORECASE)
_CASE = re.compile(r"^Test [Cc]ase ['\"](.+?)['\"] (started|passed|failed|skipped)(?:.*?\(([\d.]+) seconds\))?\.?$")
_SUITE_STARTED = re.compile(r"^Test Suite ['\"].+['\"] started(?: at .+)?\.?$")
_ACTIVE = {}
_ORIGINAL_HANDLERS = {}
_CANCELLATION_SCOPES = []


def _identifier(value):
    if value.startswith("-[") and value.endswith("]"):
        value = value[2:-1].replace(" ", "/", 1)
    elif "/" not in value:
        value = value.rsplit(".", 1)
        value = "/".join(value)
    return value.replace(".", "/").removesuffix("()")


_BUILD_MARKERS = {
    "Command line invocation:": "xcode_invocation",
    "Resolve Package Graph": "package_resolution_started",
    "Resolved source packages:": "package_resolution_completed",
}


class _Evidence:
    def __init__(self, stage, started, cwd):
        self.stage = stage
        self.started = started
        self.cwd = cwd or Path.cwd()
        self.first_issue = None
        self.test_cases = []
        self.pending = set()
        self.startup_seconds = None
        self.first_output_seconds = None
        self.build_milestones = {}

    def issue(self, message, file=None, line=None):
        file = _source_path(file, self.cwd)
        if self.first_issue is None:
            self.first_issue = {"file": file, "line": line, "message": message,
                                "elapsed_seconds": round(time.monotonic() - self.started, 3)}
        annotate("error", message, file=file, line=line, title=self.stage)

    def consume(self, text):
        text = _ANSI.sub("", text).strip()
        if text and self.first_output_seconds is None:
            self.first_output_seconds = round(time.monotonic() - self.started, 3)
        marker = _BUILD_MARKERS.get(text)
        if text.startswith("Build description signature:"):
            marker = "build_description"
        if marker and marker not in self.build_milestones:
            self.build_milestones[marker] = round(time.monotonic() - self.started, 3)
        if _SUITE_STARTED.match(text):
            if self.startup_seconds is None:
                self.startup_seconds = time.monotonic() - self.started
            return
        case = _CASE.match(text)
        if case:
            identifier, status, duration = case.groups()
            identifier = _identifier(identifier)
            if status == "started":
                if self.startup_seconds is None:
                    self.startup_seconds = time.monotonic() - self.started
                self.pending.add(identifier)
            else:
                self.pending.discard(identifier)
                self.test_cases.append({"identifier": identifier, "status": status,
                                        "duration_seconds": float(duration) if duration is not None else None})
                if status == "failed":
                    self.issue(f"XCTest failed: {identifier}")
            return
        source = _SOURCE_ERROR.match(text)
        if source:
            file, line, message = source.groups()
            self.issue(message, file, int(line))
        elif _TOOL_ERROR.match(text):
            self.issue(text)


def _utc_now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _write_metrics(directory, metrics):
    if not directory:
        return
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=directory, prefix=".command-", suffix=".tmp", delete=False) as output:
            temporary = Path(output.name)
            json.dump(metrics, output, ensure_ascii=False, allow_nan=False)
            output.write("\n")
        temporary.replace(directory / f"command-{uuid.uuid4().hex}.json")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def _kill_group(process, signum):
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def _cancel_active(signum, frame):
    active = tuple(_ACTIVE.values())
    for event in tuple(_CANCELLATION_SCOPES):
        event.set()
    if active or _CANCELLATION_SCOPES:
        for cancellation in active:
            cancellation[0] = signum
        return
    # The last command may finish on a worker, which cannot restore handlers.
    # Forward idle signals rather than swallowing cancellation of the caller.
    original = _ORIGINAL_HANDLERS.get(signum, signal.SIG_DFL)
    if original == signal.SIG_IGN:
        return
    if callable(original):
        original(signum, frame)
    else:
        signal.signal(signum, original)
        os.kill(os.getpid(), signum)


def _install_handlers():
    if threading.current_thread() is threading.main_thread():
        for signum in (signal.SIGINT, signal.SIGTERM):
            if signal.getsignal(signum) is not _cancel_active:
                _ORIGINAL_HANDLERS[signum] = signal.signal(signum, _cancel_active)


def _restore_handlers():
    if threading.current_thread() is threading.main_thread() and not _ACTIVE and not _CANCELLATION_SCOPES:
        for signum, handler in _ORIGINAL_HANDLERS.items():
            signal.signal(signum, handler)
        _ORIGINAL_HANDLERS.clear()


@contextmanager
def cancellation_scope(cancel_event=None):
    """Protect an entire executor lifetime, including before its first command.

    Enter on the main thread and pass the yielded Event to every batch command.
    """
    if threading.current_thread() is not threading.main_thread():
        raise ValueError("cancellation_scope must be entered on the main thread")
    event = cancel_event if cancel_event is not None else threading.Event()
    _CANCELLATION_SCOPES.append(event)
    _install_handlers()
    try:
        yield event
    finally:
        _CANCELLATION_SCOPES.remove(event)
        _restore_handlers()


def run_command(arguments, *, stage, timeout, log_path=None, capture=False, env=None, cwd=None, cancel_event=None, startup_timeout=None):
    """Run without a shell; env follows subprocess's replacement-environment semantics.

    Workers share cancellation with a concurrently active main-thread command.
    POSIX process groups are required (the CI runners are Linux and macOS).
    An optional threading.Event cancels a whole caller-owned concurrent batch.
    startup_timeout requires a native XCTest suite/case start, not a build banner.
    """
    if not math.isfinite(timeout) or timeout <= 0:
        raise ValueError("timeout must be a finite positive number")
    if startup_timeout is not None and (not math.isfinite(startup_timeout) or startup_timeout <= 0):
        raise ValueError("startup_timeout must be a finite positive number")
    if not arguments:
        raise ValueError("a command is required")
    started = time.monotonic()
    started_at = _utc_now()
    evidence = _Evidence(stage, started, cwd)
    context = os.environ if env is None else {**os.environ, **env}
    results_directory = context.get("CI_RESULTS_DIR")
    metrics = {"stage": stage, "started_at": started_at,
               **{key: context[key] for key in ("GITHUB_SHA", "GITHUB_RUN_ATTEMPT", "CI_MODE", "CI_FILTER") if key in context}}
    process = None
    selector = selectors.DefaultSelector()
    log = None
    captured = []
    returncode = 1
    timed_out = False
    startup_timed_out = False
    cancellation = [None]
    key = uuid.uuid4().hex
    _ACTIVE[key] = cancellation
    try:
        _install_handlers()
        if log_path is not None:
            Path(log_path).parent.mkdir(parents=True, exist_ok=True)
            log = open(log_path, "wb")
        if cancel_event is not None and cancel_event.is_set():
            returncode = 143
            evidence.issue(f"{stage} cancelled before launch")
            raise CommandError(stage, returncode)
        try:
            process = subprocess.Popen(arguments, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, start_new_session=True)
        except OSError as error:
            returncode = 127 if isinstance(error, FileNotFoundError) else 126
            evidence.issue(f"Unable to start {stage}: {error.strerror}")
            raise CommandError(stage, returncode) from error
        for stream, destination in ((process.stdout, sys.stdout), (process.stderr, sys.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, {
                "destination": destination, "decoder": codecs.getincrementaldecoder("utf-8")("replace"),
                "pending": "", "stdout": stream is process.stdout,
            })
        deadline = started + timeout
        stop_at = None
        kill_at = None
        drain_at = None
        while selector.get_map() or process.poll() is None:
            now = time.monotonic()
            if cancellation[0] is None and cancel_event is not None and cancel_event.is_set():
                cancellation[0] = signal.SIGTERM
            startup_expired = (startup_timeout is not None and now >= started + startup_timeout
                               and (evidence.startup_seconds is None or evidence.startup_seconds > startup_timeout))
            if stop_at is None and (cancellation[0] is not None or now >= deadline or startup_expired):
                timed_out = cancellation[0] is None
                startup_timed_out = timed_out and startup_expired
                returncode = 124 if timed_out else 128 + cancellation[0]
                if startup_timed_out:
                    evidence.issue(f"{stage} exceeded its {startup_timeout:g}s XCTest startup deadline without a native Test Suite/Test Case start")
                else:
                    evidence.issue(f"{stage} exceeded its {timeout:g}s deadline" if timed_out else f"{stage} cancelled by signal {cancellation[0]}")
                _kill_group(process, signal.SIGTERM)
                stop_at = now
            if stop_at is None and process.poll() is not None and selector.get_map():
                if drain_at is None:
                    drain_at = now + 2
                elif now >= drain_at:
                    returncode = process.returncode or 1
                    evidence.issue(f"{stage} exited but descendants kept output streams open")
                    _kill_group(process, signal.SIGTERM)
                    stop_at = now
            if stop_at is not None and kill_at is None and now >= stop_at + 3:
                _kill_group(process, signal.SIGKILL)
                kill_at = now
            if kill_at is not None and now >= kill_at + 2:
                break
            for selected, _ in selector.select(timeout=0.1):
                stream, state = selected.fileobj, selected.data
                try:
                    chunk = os.read(stream.fileno(), 65536)
                except BlockingIOError:
                    continue
                if log is not None and chunk:
                    log.write(chunk)
                    log.flush()
                text = state["decoder"].decode(chunk, final=not chunk)
                if text:
                    state["destination"].write(text)
                    state["destination"].flush()
                    if capture and state["stdout"]:
                        captured.append(text)
                    state["pending"] += text
                while "\n" in state["pending"]:
                    line, state["pending"] = state["pending"].split("\n", 1)
                    evidence.consume(line)
                # Raw output/logs stay complete; diagnostic parsing never buffers an unbounded line.
                if len(state["pending"]) > 65536:
                    evidence.consume(state["pending"][:65536])
                    state["pending"] = ""
                if not chunk:
                    if state["pending"]:
                        evidence.consume(state["pending"])
                    selector.unregister(stream)
                    stream.close()
            if stop_at is not None and process.poll() is not None and not selector.get_map():
                # Also kill descendants that closed their pipes but ignored SIGTERM.
                _kill_group(process, signal.SIGKILL)
                break
        if stop_at is None:
            returncode = process.wait(timeout=1)
        if returncode < 0:
            returncode = 128 - returncode
        if returncode == 0 and startup_timeout is not None and (evidence.startup_seconds is None or evidence.startup_seconds > startup_timeout):
            returncode = 124
            timed_out = True
            startup_timed_out = True
            evidence.issue(f"{stage} exited without a native XCTest start within its {startup_timeout:g}s startup deadline")
        if returncode and evidence.first_issue is None:
            evidence.issue(f"{stage} exited with status {returncode}; see the raw command log")
        if returncode:
            raise CommandError(stage, returncode)
        return "".join(captured) if capture else ""
    except KeyboardInterrupt as error:
        returncode = 130
        evidence.issue(f"{stage} interrupted")
        raise CommandError(stage, returncode) from error
    finally:
        if process is not None:
            # No reader threads and no unbounded waits, even for broken pipes or cancellation.
            if process.poll() is None:
                _kill_group(process, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    _kill_group(process, signal.SIGKILL)
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        evidence.issue(f"{stage} did not reap after SIGKILL")
            if returncode != 0:
                _kill_group(process, signal.SIGKILL)
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
        selector.close()
        if log is not None:
            log.close()
        _ACTIVE.pop(key, None)
        _restore_handlers()
        metrics.update({"completed_at": _utc_now(), "elapsed_seconds": round(time.monotonic() - started, 3),
                        "returncode": returncode, "timed_out": timed_out, "first_issue": evidence.first_issue,
                        "startup_seconds": round(evidence.startup_seconds, 3) if evidence.startup_seconds is not None else None,
                        "startup_timed_out": startup_timed_out,
                        "first_output_seconds": evidence.first_output_seconds,
                        "build_milestones": evidence.build_milestones,
                        "test_cases": evidence.test_cases, "incomplete_test_cases": sorted(evidence.pending)})
        try:
            _write_metrics(results_directory, metrics)
        except OSError as error:
            annotate("error", f"Unable to retain command metrics: {error.strerror}", title=stage)
            if returncode == 0:
                raise CommandError(stage, 1) from error


def _markdown(value):
    return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("|", "&#124;").replace("\r", " ").replace("\n", " ")


def summarize(title):
    directory = os.environ.get("CI_RESULTS_DIR")
    paths = sorted(Path(directory).glob("command-*.json")) if directory else []
    records = []
    errors = []
    for path in paths:
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(record, dict) or not {"stage", "returncode", "elapsed_seconds", "test_cases", "first_issue", "started_at", "completed_at", "timed_out"} <= record.keys():
                raise ValueError("missing command evidence fields")
            records.append(record)
        except (OSError, ValueError) as error:
            errors.append(f"Unreadable metrics {path.name}: {error}")
    records.sort(key=lambda record: record["started_at"])
    lines = [f"## {_markdown(title)}", ""]
    for key in ("GITHUB_SHA", "GITHUB_RUN_ATTEMPT", "CI_MODE", "CI_FILTER"):
        values = sorted({str(record[key]) for record in records if key in record} | ({os.environ[key]} if key in os.environ else set()))
        if values:
            lines.append(f"- {key}: {_markdown(', '.join(values))}")
    lines += ["", "Observed finished XCTest cases only; this summary is not a full-coverage gate.", "",
              "| Stage | Seconds | Exit | Passed | Failed | Skipped | Unfinished |", "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    totals = {status: 0 for status in ("passed", "failed", "skipped")}
    unfinished = 0
    issues = []
    for record in records:
        counts = {status: sum(case["status"] == status for case in record["test_cases"]) for status in totals}
        for status in totals:
            totals[status] += counts[status]
        pending = len(record.get("incomplete_test_cases", []))
        unfinished += pending
        lines.append(f"| {_markdown(record['stage'])} | {record['elapsed_seconds']:.3f} | {record['returncode']} | {counts['passed']} | {counts['failed']} | {counts['skipped']} | {pending} |")
        if record["first_issue"]:
            issue = record["first_issue"]
            location = f"{issue['file']}:{issue['line']}: " if issue.get("file") else ""
            issues.append(f"First issue ({_markdown(record['stage'])}, +{issue['elapsed_seconds']:.3f}s): {_markdown(location + issue['message'])}")
    lines += ["", f"Finished observations: {totals['passed']} passed, {totals['failed']} failed, {totals['skipped']} skipped; {unfinished} started cases did not finish."]
    lines.extend(["", *issues])
    if not records:
        lines.append("**No command evidence was recorded; coverage is unknown/incomplete.**")
    if unfinished or totals["failed"] or any(record["returncode"] != 0 for record in records) or errors:
        lines.append("**Failed or incomplete execution: do not infer full coverage from passing cases.**")
    lines.extend(f"- {_markdown(error)}" for error in errors)
    text = "\n".join(lines) + "\n"
    print(text, end="")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write(text)
    if errors:
        raise CommandError("summary", 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="action", required=True)
    run = subparsers.add_parser("run")
    run.add_argument("--stage", required=True)
    run.add_argument("--timeout", type=float, required=True)
    run.add_argument("--startup-timeout", type=float)
    run.add_argument("--log", dest="log_path")
    run.add_argument("arguments", nargs=argparse.REMAINDER)
    summary = subparsers.add_parser("summary")
    summary.add_argument("--title", required=True)
    options = parser.parse_args()
    try:
        if options.action == "summary":
            summarize(options.title)
        else:
            arguments = options.arguments[1:] if options.arguments[:1] == ["--"] else options.arguments
            if not arguments or not math.isfinite(options.timeout) or options.timeout <= 0:
                parser.error("run requires a command and a finite positive timeout")
            if options.startup_timeout is not None and (not math.isfinite(options.startup_timeout) or options.startup_timeout <= 0):
                parser.error("--startup-timeout must be a finite positive number")
            run_command(arguments, stage=options.stage, timeout=options.timeout, log_path=options.log_path,
                        startup_timeout=options.startup_timeout)
        return 0
    except CommandError as error:
        return error.returncode
    except OSError as error:
        annotate("error", f"CI runtime failed: {error.strerror}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
