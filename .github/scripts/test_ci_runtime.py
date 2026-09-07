import contextlib
import io
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from ci_runtime import CommandError, annotate, run_command, summarize


RUNTIME = Path(__file__).with_name("ci_runtime.py").resolve()


class RuntimeTests(unittest.TestCase):
    def test_native_errors_preserve_status_capture_and_raw_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Sources" / "percent%,colon:.swift"
            warning = "warning: Requested but did not find extension point Xcode.IDEKit; error recovery enabled\n"
            diagnostic = f"{source}:42:7: error: expected 100% success\n"
            raw_stdout, raw_stderr = io.StringIO(), io.StringIO()
            with patch.dict(os.environ, {"CI_RESULTS_DIR": directory, "GITHUB_WORKSPACE": directory,
                                         "GITHUB_SHA": "exact-sha", "CI_MODE": "full"}), \
                    contextlib.redirect_stdout(raw_stdout), contextlib.redirect_stderr(raw_stderr):
                with self.assertRaises(CommandError) as failure:
                    run_command([sys.executable, "-c", "import sys; sys.stdout.write('payload\\n'); sys.stdout.flush(); sys.stderr.write(sys.argv[1]); sys.exit(65)", warning + diagnostic],
                                stage="native", timeout=10, capture=True, log_path=root / "raw.log")
            self.assertEqual(failure.exception.returncode, 65)
            self.assertEqual(raw_stdout.getvalue(), "payload\n")
            stderr = raw_stderr.getvalue()
            self.assertIn(warning, stderr)
            self.assertEqual(stderr.count("::error "), 1)
            self.assertIn("file=Sources/percent%25%2Ccolon%3A.swift,line=42,title=native", stderr)
            self.assertIn("expected 100%25 success", stderr)
            self.assertNotIn("::warning", stderr)
            log = (root / "raw.log").read_bytes()
            self.assertIn(diagnostic.encode(), log)
            self.assertNotIn(b"::error", log)
            record = json.loads(next(root.glob("command-*.json")).read_text())
            self.assertEqual(record["returncode"], 65)
            self.assertEqual(record["first_issue"]["line"], 42)
            self.assertEqual(record["first_issue"]["file"], "Sources/percent%,colon:.swift")
            self.assertEqual(record["GITHUB_SHA"], "exact-sha")
            self.assertNotIn("arguments", record)

    def test_capture_excludes_visible_stderr_and_annotation_escapes_injection(self):
        stderr = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(stderr), \
                patch.dict(os.environ, {"CI_RESULTS_DIR": ""}):
            captured = run_command([sys.executable, "-c", "import sys; print('stdout'); print('stderr', file=sys.stderr)"],
                                   stage="capture", timeout=10, capture=True)
            annotate("error", "first%\r\n::notice::injected", title="a,b:c\nnext")
        self.assertEqual(captured, "stdout\n")
        self.assertIn("stderr\n", stderr.getvalue())
        self.assertIn("title=a%2Cb%3Ac%0Anext::first%25%0D%0A::notice::injected\n", stderr.getvalue())
        self.assertNotIn("\n::notice", stderr.getvalue())

    def test_finished_failed_and_unfinished_cases_survive_summary(self):
        output = "\n".join([
            "Test Case '-[Target.Class testGood]' started.",
            "Test Case '-[Target.Class testGood]' passed (0.125 seconds).",
            "Test case 'Target.Class/testBad()' failed on 'iPhone 17' (1.250 seconds)",
            "Test Case '-[Target.Class testPending]' started.",
        ]) + "\n"
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"CI_RESULTS_DIR": directory, "GITHUB_STEP_SUMMARY": ""}), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            run_command([sys.executable, "-c", "import sys; sys.stdout.write(sys.argv[1])", output], stage="tests", timeout=10)
            record = json.loads(next(Path(directory).glob("command-*.json")).read_text())
            self.assertEqual(record["test_cases"], [
                {"identifier": "Target/Class/testGood", "status": "passed", "duration_seconds": 0.125},
                {"identifier": "Target/Class/testBad", "status": "failed", "duration_seconds": 1.25},
            ])
            self.assertEqual(record["incomplete_test_cases"], ["Target/Class/testPending"])
            summary = io.StringIO()
            with contextlib.redirect_stdout(summary):
                summarize("Testing")
            self.assertIn("1 passed, 1 failed, 0 skipped; 1 started cases did not finish", summary.getvalue())
            self.assertIn("Failed or incomplete execution", summary.getvalue())

    def test_annotations_arrive_before_process_finishes(self):
        with tempfile.TemporaryDirectory() as directory:
            release = Path(directory) / "release"
            script = "import os,sys,time; from pathlib import Path; os.write(2,b'Source.swift:3: error: split UTF-8 \\xe2'); time.sleep(.05); os.write(2,b'\\x98\\x83\\n');\nwhile not Path(sys.argv[1]).exists(): time.sleep(.01)"
            process = subprocess.Popen([sys.executable, str(RUNTIME), "run", "--stage", "stream", "--timeout", "8", "--", sys.executable, "-c", script, str(release)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       env={**os.environ, "CI_RESULTS_DIR": directory}, start_new_session=True)
            selector = selectors.DefaultSelector()
            selector.register(process.stderr, selectors.EVENT_READ)
            observed = b""
            deadline = time.monotonic() + 5
            try:
                while b"::error " not in observed and time.monotonic() < deadline:
                    if selector.select(0.1):
                        chunk = os.read(process.stderr.fileno(), 4096)
                        if not chunk:
                            break
                        observed += chunk
                self.assertIn(b"::error ", observed)
                self.assertIn("split UTF-8 ☃".encode(), observed)
                self.assertIsNone(process.poll())
                release.touch()
                process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0)
            finally:
                release.touch()
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                process.communicate(timeout=10)
                selector.close()

    def test_deadline_kills_sigterm_ignoring_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            heartbeat = Path(directory) / "heartbeat"
            child = "import signal,time; from pathlib import Path; signal.signal(signal.SIGTERM, signal.SIG_IGN); p=Path(" + repr(str(heartbeat)) + ");\nwhile True: p.write_text(str(time.monotonic())); time.sleep(.02)"
            parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',sys.argv[1]]); time.sleep(60)"
            before = time.monotonic()
            with patch.dict(os.environ, {"CI_RESULTS_DIR": directory}), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(CommandError) as failure:
                    run_command([sys.executable, "-c", parent, child], stage="deadline", timeout=1)
            self.assertEqual(failure.exception.returncode, 124)
            self.assertLess(time.monotonic() - before, 9)
            value = heartbeat.read_text()
            time.sleep(0.15)
            self.assertEqual(heartbeat.read_text(), value)
            record = json.loads(next(Path(directory).glob("command-*.json")).read_text())
            self.assertTrue(record["timed_out"])
            self.assertEqual(record["returncode"], 124)

    def test_cli_preserves_signal_exit_and_pre_cancelled_batch_never_launches(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(RUNTIME), "run", "--stage", "signal", "--timeout", "10", "--", sys.executable, "-c", "import os,signal; os.kill(os.getpid(),signal.SIGTERM)"],
                                    env={**os.environ, "CI_RESULTS_DIR": directory}, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 143)
            event = threading.Event()
            event.set()
            marker = Path(directory) / "must-not-exist"
            with patch.dict(os.environ, {"CI_RESULTS_DIR": directory}), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(CommandError) as failure:
                    run_command([sys.executable, "-c", "from pathlib import Path; Path(" + repr(str(marker)) + ").touch()"],
                                stage="cancelled", timeout=10, cancel_event=event)
            self.assertEqual(failure.exception.returncode, 143)
            self.assertFalse(marker.exists())

    def test_signal_cancels_workers_after_main_command_has_finished(self):
        with tempfile.TemporaryDirectory() as directory:
            ready = Path(directory) / "ready"
            worker_ready = Path(directory) / "worker-ready"
            child = "import time; from pathlib import Path; Path(" + repr(str(worker_ready)) + ").touch(); time.sleep(60)"
            script = "\n".join([
                "import sys,threading,time",
                "from pathlib import Path",
                "from ci_runtime import CommandError,run_command",
                "def worker():",
                "    try:",
                "        run_command([sys.executable,'-c',sys.argv[1]],stage='worker',timeout=15)",
                "    except CommandError as error:",
                "        print('worker-status',error.returncode,flush=True)",
                "thread=threading.Thread(target=worker)",
                "thread.start()",
                "while not Path(sys.argv[2]).exists(): time.sleep(.01)",
                "run_command([sys.executable,'-c','pass'],stage='main',timeout=5)",
                "Path(sys.argv[3]).touch()",
                "thread.join()",
            ])
            process = subprocess.Popen([sys.executable, "-c", script, child, str(worker_ready), str(ready)],
                                       cwd=RUNTIME.parent, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       env={**os.environ, "CI_RESULTS_DIR": directory})
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(ready.exists())
                process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr.decode())
                self.assertIn(b"worker-status 143", stdout)
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                process.communicate(timeout=20)

    def test_scope_cancels_before_first_launch_and_restores_idle_signals(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "must-not-exist"
            child = "from pathlib import Path; Path(" + repr(str(marker)) + ").touch()"
            script = "\n".join([
                "import os,signal,sys",
                "from ci_runtime import CommandError,cancellation_scope,run_command",
                "with cancellation_scope() as cancelled:",
                "    os.kill(os.getpid(),signal.SIGTERM)",
                "    try:",
                "        run_command([sys.executable,'-c',sys.argv[1]],stage='cancelled',timeout=5,cancel_event=cancelled)",
                "    except CommandError as error:",
                "        print('cancelled-status',error.returncode,flush=True)",
                "os.kill(os.getpid(),signal.SIGTERM)",
            ])
            result = subprocess.run([sys.executable, "-c", script, child], cwd=RUNTIME.parent,
                                    env={**os.environ, "CI_RESULTS_DIR": directory},
                                    capture_output=True, timeout=10)
            self.assertIn(b"cancelled-status 143", result.stdout)
            self.assertEqual(result.returncode, -signal.SIGTERM)
            self.assertFalse(marker.exists())

    def test_startup_deadline_requires_timely_native_xctest_start(self):
        native_start = "Test Suite 'All tests' started at 2026-09-07 12:00:00.000."
        cases = [
            ("banner-only", "print('Testing started',flush=True)", 124),
            ("late-native", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('Testing started',flush=True); time.sleep(1.2); print(" + repr(native_start) + ",flush=True)", 124),
            ("native", "import time; print(" + repr(native_start) + ",flush=True); time.sleep(1.2); print(\"Test Case '-[Target.Class testGood]' started.\"); print(\"Test Case '-[Target.Class testGood]' passed (0.010 seconds).\")", 0),
        ]
        for stage, script, expected in cases:
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as directory:
                result = subprocess.run([sys.executable, str(RUNTIME), "run", "--stage", stage,
                                         "--timeout", "8", "--startup-timeout", "1", "--",
                                         sys.executable, "-c", script],
                                        env={**os.environ, "CI_RESULTS_DIR": directory},
                                        capture_output=True, timeout=12)
                self.assertEqual(result.returncode, expected, result.stderr.decode())
                record = json.loads(next(Path(directory).glob("command-*.json")).read_text())
                self.assertEqual(record["startup_timed_out"], expected == 124)
                if stage == "banner-only":
                    self.assertIsNone(record["startup_seconds"])
                elif stage == "late-native":
                    self.assertGreater(record["startup_seconds"], 1)
                else:
                    self.assertLess(record["startup_seconds"], 1)
                    self.assertEqual(record["test_cases"], [
                        {"identifier": "Target/Class/testGood", "status": "passed", "duration_seconds": 0.01},
                    ])


if __name__ == "__main__":
    unittest.main()
