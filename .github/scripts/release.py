#!/usr/bin/env python3
"""Bounded release phases; credentials remain private and upload acceptance explicit."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import time
import urllib.error
import urllib.parse
import urllib.request

from ci_runtime import CommandError, annotate, run_command
from manage_api_certificates import NoRedirects, required_environment
from validate_bundles import VERSION_PATTERN, load_project, validate_built, validate_source

FULL_JOBS = {
    "CI / preflight", "Swift package tests", "iOS / build and smoke",
    "iOS / functional", "iOS / integration", "Apple Watch companion",
    "CI / full verification",
}


def output(name: str, value: str, destination: str = "GITHUB_OUTPUT") -> None:
    if "\n" in value or "\r" in value:
        raise ValueError(f"Invalid multiline release output: {name}")
    path = os.environ.get(destination)
    if path:
        with Path(path).open("a", encoding="utf-8") as stream:
            stream.write(f"{name}={value}\n")


def resolve_version() -> None:
    validate_source()
    version = os.environ.get("INPUT_MARKETING_VERSION", "")
    if os.environ.get("GITHUB_EVENT_NAME") == "push":
        ref = required_environment("GITHUB_REF_NAME")
        if not ref.startswith("v"):
            raise ValueError("A pushed release tag must start with v")
        version = ref[1:]
    elif not version:
        version = str(load_project()["targets"]["OTodo"]["settings"]["base"]["MARKETING_VERSION"])
    if not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError(f"Invalid marketing version {version!r}; use one to three dot-separated integers")
    # The workflow-global release lock is acquired before this job starts.
    build = str(int(time.time()))
    for key, value in (("MARKETING_VERSION", version), ("BUILD_NUMBER", build)):
        output(key, value, "GITHUB_ENV")
    output("version", version)
    output("build", build)
    print(f"Resolved marketing version {version}; serialized epoch build {build}.")


def github_get(path: str) -> dict:
    root = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    request = urllib.request.Request(root + path, headers={
        "Authorization": "Bearer " + required_environment("GH_TOKEN"),
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    try:
        with urllib.request.build_opener(NoRedirects).open(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"GitHub verification lookup {path} failed with HTTP {error.code}: "
                           + error.read().decode("utf-8", errors="replace")) from error


def github_pages(path: str, field: str) -> list[dict]:
    results = []
    separator = "&" if "?" in path else "?"
    for page in range(1, 1001):
        response = github_get(f"{path}{separator}per_page=100&page={page}")
        items = response.get(field)
        if not isinstance(items, list):
            raise RuntimeError(f"GitHub returned invalid {field} data")
        results.extend(items)
        if len(items) < 100:
            return results
    raise RuntimeError(f"GitHub {field} pagination exceeded the safety limit")


def verify_ci() -> None:
    repository = required_environment("GITHUB_REPOSITORY")
    sha = required_environment("GITHUB_SHA")
    query = urllib.parse.urlencode({"head_sha": sha, "status": "success"})
    runs = github_pages(f"/repos/{repository}/actions/workflows/ci.yml/runs?{query}", "workflow_runs")
    for run in runs:
        if (run.get("head_sha") != sha or run.get("status") != "completed"
                or run.get("conclusion") != "success" or run.get("path") != ".github/workflows/ci.yml"):
            continue
        jobs = github_pages(f"/repos/{repository}/actions/runs/{run['id']}/jobs?filter=all", "jobs")
        # Reruns can retain successful jobs from prior attempts. For each name,
        # only its newest execution is authoritative; a stale green cannot mask red.
        effective = {}
        for job in jobs:
            name = job.get("name")
            if name in FULL_JOBS and job.get("id", 0) > effective.get(name, {}).get("id", 0):
                effective[name] = job
        if all(effective.get(name, {}).get("conclusion") == "success"
               and effective[name].get("status") == "completed"
               and effective[name].get("head_sha") == sha for name in FULL_JOBS):
            print(f"Full exact-SHA CI verified: {run['html_url']} ({sha})")
            output("ci_url", run["html_url"])
            return
    raise RuntimeError(
        f"No successful full .github/workflows/ci.yml verification exists for exact SHA {sha}; "
        "all seven canonical jobs, including 'CI / full verification', must succeed. "
        "Focused/diagnostic green runs cannot authorize release."
    )


def install_key() -> None:
    key = required_environment("API_KEY")
    path = Path(required_environment("API_KEY_PATH"))
    path.parent.mkdir(parents=True, exist_ok=True)
    # Opening with 0600 prevents a window of exposure before chmod.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(key)
    try:
        if not key.startswith("-----BEGIN PRIVATE KEY-----") or "-----END PRIVATE KEY-----" not in key:
            raise ValueError("APP_STORE_CONNECT_API_KEY must contain the complete PEM .p8 private key")
        run_command(["openssl", "pkey", "-in", str(path), "-noout", "-check"],
                    stage="release-key-validation", timeout=15)
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def authentication_arguments() -> list[str]:
    return ["-allowProvisioningUpdates", "-authenticationKeyPath", required_environment("API_KEY_PATH"),
            "-authenticationKeyID", required_environment("KEY_ID"),
            "-authenticationKeyIssuerID", required_environment("ISSUER_ID")]


def archive() -> None:
    run_command([
        "xcodebuild", "archive", "-project", required_environment("PROJECT"),
        "-scheme", required_environment("SCHEME"), "-configuration", "Release",
        "-destination", "generic/platform=iOS", "-archivePath", required_environment("ARCHIVE_PATH"),
        "-showBuildTimingSummary",
        *authentication_arguments(), "CODE_SIGN_STYLE=Automatic", "DEVELOPMENT_TEAM=9492A97LWY",
        "REGISTER_APP_GROUPS=YES", "GITHUB_CLIENT_ID=" + required_environment("GITHUB_CLIENT_ID"),
        "CURRENT_PROJECT_VERSION=" + required_environment("BUILD_NUMBER"),
        "MARKETING_VERSION=" + required_environment("MARKETING_VERSION"),
    ], stage="release-archive", timeout=1200, log_path=Path(required_environment("RELEASE_LOG_DIR")) / "archive.log")
    validate_built(Path(required_environment("ARCHIVE_PATH")) / "Products/Applications/OTodo.app",
                   "archive", required_environment("MARKETING_VERSION"), required_environment("BUILD_NUMBER"))


def export() -> None:
    export_dir = Path(required_environment("EXPORT_DIR"))
    run_command([
        "xcodebuild", "-exportArchive", "-archivePath", required_environment("ARCHIVE_PATH"),
        "-exportPath", str(export_dir), "-exportOptionsPlist", "ExportOptions.plist",
        *authentication_arguments(),
    ], stage="release-export", timeout=600, log_path=Path(required_environment("RELEASE_LOG_DIR")) / "export.log")
    ipas = list(export_dir.glob("*.ipa"))
    if len(ipas) != 1:
        raise RuntimeError(f"Export produced {len(ipas)} IPAs; expected exactly one for OTodo")
    output("IPA_PATH", str(ipas[0]), "GITHUB_ENV")
    output("ipa_created", "true")
    print(f"Exported {ipas[0].name}.")


def upload() -> None:
    keys_dir = Path.home() / ".appstoreconnect/private_keys"
    keys_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    keys_dir.chmod(0o700)
    named_key = keys_dir / f"AuthKey_{required_environment('KEY_ID')}.p8"
    log_path = Path(required_environment("RELEASE_LOG_DIR")) / "testflight-upload.log"
    try:
        shutil.copyfile(required_environment("API_KEY_PATH"), named_key)
        named_key.chmod(0o600)
        output("attempted", "true")
        run_command([
            "xcrun", "altool", "--upload-app", "--type", "ios", "--file", required_environment("IPA_PATH"),
            "--apiKey", required_environment("KEY_ID"), "--apiIssuer", required_environment("ISSUER_ID"),
        ], stage="release-testflight-upload", timeout=600, log_path=log_path)
        text = log_path.read_text(encoding="utf-8", errors="replace")
        if re.search(r"UPLOAD FAILED|Failed to upload package", text, re.IGNORECASE):
            raise RuntimeError("TestFlight upload reported failure; see the preserved altool diagnostic")
        if not re.search(r"UPLOAD SUCCEEDED|No errors uploading", text, re.IGNORECASE):
            raise RuntimeError("TestFlight upload did not report synchronous acceptance; do not assume it was accepted")
        output("accepted", "true")
        print("TestFlight upload accepted synchronously; App Store Connect processing is pending.")
    except BaseException:
        output("failed", "true")
        raise
    finally:
        named_key.unlink(missing_ok=True)


def sanitize_diagnostics() -> None:
    # GitHub masks console output, not bytes in uploaded artifacts. Xcode echoes
    # its authentication arguments, so redact before any log/metrics transport.
    secrets = {os.environ.get(name, "") for name in ("KEY_ID", "ISSUER_ID", "API_KEY")}
    secrets.update(os.environ.get("API_KEY", "").splitlines())
    secrets.discard("")
    for variable, pattern in (("RELEASE_LOG_DIR", "*.log"), ("CI_RESULTS_DIR", "*.json")):
        for path in Path(required_environment(variable)).glob(pattern):
            text = path.read_text(encoding="utf-8", errors="replace")
            for secret in sorted(secrets, key=len, reverse=True):
                text = text.replace(secret, "***")
            path.write_text(text, encoding="utf-8")


def main() -> None:
    commands = {"version": resolve_version, "verify-ci": verify_ci, "install-key": install_key,
                "archive": archive, "export": export, "upload": upload,
                "sanitize-diagnostics": sanitize_diagnostics}
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=commands)
    arguments = parser.parse_args()
    commands[arguments.command]()


if __name__ == "__main__":
    try:
        main()
    except CommandError as error:
        annotate("error", str(error), title="Release")
        raise SystemExit(error.returncode)
    except Exception as error:
        annotate("error", str(error), title="Release")
        raise SystemExit(1)
