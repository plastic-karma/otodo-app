import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import manage_api_certificates as certificates
import release
from ci_runtime import CommandError


def ephemeral(identifier):
    return {"id": identifier, "attributes": {"certificateType": "DISTRIBUTION", "name": "Created via API"}}


class CertificateSafetyTests(unittest.TestCase):
    def test_paginated_snapshot_includes_existing_certificates_on_later_pages(self):
        pages = iter([
            {"data": [ephemeral("first")], "links": {"next": certificates.API_ROOT + "/certificates?cursor=second"}},
            {"data": [ephemeral("last")], "links": {"next": None}},
        ])
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / "before.json"
            with patch.dict(os.environ, {"GITHUB_RUN_ID": "run", "CERTIFICATE_SNAPSHOT": str(snapshot), "BOOTSTRAP_CERTIFICATE_SHA1": ""}), \
                    patch.object(certificates, "request", side_effect=lambda *args: json.dumps(next(pages)).encode()):
                certificates.prepare()
            self.assertEqual(json.loads(snapshot.read_text())["before_ids"], ["first", "last"])

    def test_untrusted_pagination_cannot_receive_authorization(self):
        first_page = {"data": [ephemeral("first")], "links": {"next": "https://attacker.invalid/v1/certificates"}}
        requested = []

        def request(method, url):
            requested.append(url)
            return json.dumps(first_page).encode()

        with patch.object(certificates, "request", side_effect=request):
            with self.assertRaisesRegex(RuntimeError, "unsafe"):
                certificates.list_certificates()
        self.assertEqual(requested, [certificates.API_ROOT + "/certificates?limit=200"])

    def test_cleanup_retry_never_revokes_an_intervening_releases_certificate(self):
        with tempfile.TemporaryDirectory() as directory:
            before = Path(directory) / "before.json"
            plan = Path(directory) / "allowlist.json"
            before.write_text(json.dumps({"run_id": "run", "before_ids": ["existing"]}))
            environment = {"GITHUB_RUN_ID": "run", "CERTIFICATE_SNAPSHOT": str(before), "CERTIFICATE_CLEANUP_PLAN": str(plan)}
            with patch.dict(os.environ, environment):
                with patch.object(certificates, "list_certificates", return_value=[ephemeral("existing"), ephemeral("ours")]):
                    certificates.capture()
                revoked = []
                with patch.object(certificates, "list_certificates", return_value=[ephemeral("existing"), ephemeral("ours"), ephemeral("later-release")]), \
                        patch.object(certificates, "revoke", side_effect=lambda item: revoked.append(item["id"])):
                    certificates.cleanup()
                self.assertEqual(revoked, ["ours"])
                # A repeat after successful revocation is harmless, even if the
                # later release's certificate is still present.
                with patch.object(certificates, "list_certificates", return_value=[ephemeral("existing"), ephemeral("later-release")]), \
                        patch.object(certificates, "revoke", side_effect=lambda item: revoked.append(item["id"])):
                    certificates.cleanup()
                self.assertEqual(revoked, ["ours"])

    def test_cleanup_rejects_preexisting_ids_in_allowlist(self):
        with tempfile.TemporaryDirectory() as directory:
            plan = Path(directory) / "allowlist.json"
            plan.write_text(json.dumps({"run_id": "run", "before_ids": ["existing"], "created_ids": ["existing"]}))
            with patch.dict(os.environ, {"GITHUB_RUN_ID": "run", "CERTIFICATE_CLEANUP_PLAN": str(plan)}), \
                    patch.object(certificates, "revoke") as revoke:
                with self.assertRaisesRegex(RuntimeError, "pre-existing"):
                    certificates.cleanup()
                revoke.assert_not_called()


class FullVerificationTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_SHA": "exact-sha"})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.run = {"id": 10, "head_sha": "exact-sha", "status": "completed", "conclusion": "success",
                    "path": ".github/workflows/ci.yml", "html_url": "https://github.com/owner/repo/actions/runs/10"}
        names = ["CI / preflight", "Swift package tests", "iOS / build and smoke", "iOS / functional",
                 "iOS / integration", "Apple Watch companion", "CI / full verification"]
        self.jobs = [{"id": index + 1, "name": name, "head_sha": "exact-sha", "status": "completed",
                      "conclusion": "success"} for index, name in enumerate(names)]

    def test_focused_green_cannot_authorize_release(self):
        with patch.object(release, "github_pages", side_effect=[[self.run], self.jobs[:-1]]):
            with self.assertRaisesRegex(RuntimeError, "No successful full"):
                release.verify_ci()

    def test_stale_green_job_cannot_mask_newer_failed_execution(self):
        failed_rerun = {**self.jobs[-1], "id": 100, "conclusion": "failure"}
        with patch.object(release, "github_pages", side_effect=[[self.run], [failed_rerun, *self.jobs]]):
            with self.assertRaisesRegex(RuntimeError, "No successful full"):
                release.verify_ci()

    def test_successful_rerun_can_inherit_original_successful_jobs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            final_rerun = {**self.jobs[-1], "id": 100}
            with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}), \
                    patch.object(release, "github_pages", side_effect=[[self.run], [*self.jobs[:-1], final_rerun]]):
                release.verify_ci()
            self.assertEqual(output.read_text().strip(), "ci_url=" + self.run["html_url"])

    def test_other_sha_cannot_authorize_release(self):
        with patch.object(release, "github_pages", return_value=[{**self.run, "head_sha": "other-sha"}]):
            with self.assertRaisesRegex(RuntimeError, "exact SHA"):
                release.verify_ci()


class UploadOutcomeTests(unittest.TestCase):
    def exercise_upload(self, runner):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = root / "key.p8"
            key.write_text("private-test-key")
            output = root / "outputs"
            environment = {"KEY_ID": "TESTKEY", "ISSUER_ID": "issuer", "API_KEY_PATH": str(key),
                           "IPA_PATH": str(root / "OTodo.ipa"), "RELEASE_LOG_DIR": str(root), "GITHUB_OUTPUT": str(output)}
            error = None
            with patch.dict(os.environ, environment), patch.object(Path, "home", return_value=root), \
                    patch.object(release, "run_command", side_effect=runner):
                try:
                    release.upload()
                except RuntimeError as caught:
                    error = caught
            state = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertFalse((root / ".appstoreconnect/private_keys/AuthKey_TESTKEY.p8").exists())
            return state, error

    def test_nonzero_upload_preserves_failure_and_never_claims_acceptance(self):
        def runner(*args, **kwargs):
            raise CommandError("release-testflight-upload", 65)

        state, error = self.exercise_upload(runner)
        self.assertEqual(state, {"attempted": "true", "failed": "true"})
        self.assertIsInstance(error, CommandError)
        self.assertEqual(error.returncode, 65)

    def test_zero_status_without_apple_acceptance_is_not_success(self):
        def runner(*args, **kwargs):
            Path(kwargs["log_path"]).write_text("Upload request started, no acceptance response.\n")

        state, error = self.exercise_upload(runner)
        self.assertEqual(state, {"attempted": "true", "failed": "true"})
        self.assertIsNotNone(error)

    def test_confirmed_synchronous_upload_is_accepted_not_merely_attempted(self):
        def runner(*args, **kwargs):
            Path(kwargs["log_path"]).write_text("No errors uploading 'OTodo.ipa'\nUPLOAD SUCCEEDED\n")

        state, error = self.exercise_upload(runner)
        self.assertEqual(state, {"attempted": "true", "accepted": "true"})
        self.assertIsNone(error)


class DiagnosticPrivacyTests(unittest.TestCase):
    def test_artifact_redaction_removes_secret_values_without_hiding_native_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            logs = root / "logs"
            metrics = root / "metrics"
            logs.mkdir()
            metrics.mkdir()
            key = "-----BEGIN PRIVATE KEY-----\nsecret-base64-key-fragment\n-----END PRIVATE KEY-----"
            log = logs / "archive.log"
            log.write_text("key-id=SECRETKEY issuer=SECRETISSUER\nsecret-base64-key-fragment\nfile.swift:42: error: missing member\n")
            metric = metrics / "command.json"
            metric.write_text(json.dumps({"first_issue": {"message": "SECRETKEY: forbidden"}}))
            with patch.dict(os.environ, {"KEY_ID": "SECRETKEY", "ISSUER_ID": "SECRETISSUER", "API_KEY": key,
                                        "RELEASE_LOG_DIR": str(logs), "CI_RESULTS_DIR": str(metrics)}):
                release.sanitize_diagnostics()
            self.assertEqual(log.read_text(), "key-id=*** issuer=***\n***\nfile.swift:42: error: missing member\n")
            self.assertEqual(json.loads(metric.read_text())["first_issue"]["message"], "***: forbidden")


if __name__ == "__main__":
    unittest.main()
