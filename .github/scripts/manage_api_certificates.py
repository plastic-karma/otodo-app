#!/usr/bin/env python3
"""Read-only Apple preflight and narrowly scoped ephemeral signing cleanup."""

import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import tempfile
import urllib.error
import urllib.parse
import urllib.request

from ci_runtime import CommandError, annotate, run_command
from validate_bundles import COMPONENTS

API_ROOT = "https://api.appstoreconnect.apple.com/v1"
EPHEMERAL_CERTIFICATE_TYPES = {
    "DEVELOPMENT",
    "DISTRIBUTION",
    "IOS_DEVELOPMENT",
    "IOS_DISTRIBUTION",
}


def required_environment(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def read_der_length(value: bytes, offset: int) -> tuple[int, int]:
    first = value[offset]
    offset += 1
    if first < 0x80:
        return first, offset
    byte_count = first & 0x7F
    if byte_count == 0 or byte_count > 4:
        raise RuntimeError("Unsupported ECDSA signature length")
    end = offset + byte_count
    return int.from_bytes(value[offset:end], "big"), end


def raw_es256_signature(der_signature: bytes) -> bytes:
    offset = 0
    if not der_signature or der_signature[offset] != 0x30:
        raise RuntimeError("OpenSSL returned an invalid ECDSA signature")
    sequence_length, offset = read_der_length(der_signature, offset + 1)
    if offset + sequence_length != len(der_signature):
        raise RuntimeError("OpenSSL returned a malformed ECDSA signature")

    components: list[bytes] = []
    for _ in range(2):
        if offset >= len(der_signature) or der_signature[offset] != 0x02:
            raise RuntimeError("OpenSSL returned a malformed ECDSA integer")
        component_length, offset = read_der_length(der_signature, offset + 1)
        component = der_signature[offset : offset + component_length]
        offset += component_length
        component = component.lstrip(b"\x00")
        if len(component) > 32:
            raise RuntimeError("OpenSSL returned an oversized ES256 component")
        components.append(component.rjust(32, b"\x00"))

    if offset != len(der_signature):
        raise RuntimeError("OpenSSL returned trailing ECDSA signature data")
    return b"".join(components)


def authorization_token() -> str:
    key_id = required_environment("KEY_ID")
    issuer_id = required_environment("ISSUER_ID")
    key_path = required_environment("API_KEY_PATH")
    now = int(time.time())
    header = base64url(
        json.dumps(
            {"alg": "ES256", "kid": key_id, "typ": "JWT"},
            separators=(",", ":"),
        ).encode("utf-8")
    )
    payload = base64url(
        json.dumps(
            {
                "iss": issuer_id,
                "iat": now,
                "exp": now + 600,
                "aud": "appstoreconnect-v1",
            },
            separators=(",", ":"),
        ).encode("utf-8")
    )
    signing_input = f"{header}.{payload}".encode("ascii")
    # Keep both the JWT signing input and binary signature out of command logs.
    with tempfile.TemporaryDirectory(prefix="otodo-jwt-") as private_dir:
        input_path = Path(private_dir) / "input"
        signature_path = Path(private_dir) / "signature"
        input_path.write_bytes(signing_input)
        run_command(
            ["openssl", "dgst", "-sha256", "-sign", key_path,
             "-out", str(signature_path), str(input_path)],
            stage="apple-token-signing", timeout=15,
        )
        signature = base64url(raw_es256_signature(signature_path.read_bytes()))
    return f"{header}.{payload}.{signature}"


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Authorization must never follow an API redirect to another origin.
        return None


def api_url(path: str) -> str:
    url = path if urllib.parse.urlsplit(path).scheme else (
        "https://api.appstoreconnect.apple.com" + path
        if path.startswith("/v1/") else API_ROOT + path
    )
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != "https" or parsed.netloc != "api.appstoreconnect.apple.com"
            or not parsed.path.startswith("/v1/") or parsed.fragment):
        raise RuntimeError("Refusing an unsafe App Store Connect pagination URL")
    return url


def request(method: str, path: str) -> bytes:
    request_value = urllib.request.Request(
        api_url(path),
        method=method,
        headers={
            "Authorization": f"Bearer {authorization_token()}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.build_opener(NoRedirects).open(request_value, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        response = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"App Store Connect {method} {path} failed with HTTP "
            f"{error.code}: {response}"
        ) from error


def list_resources(path: str) -> list[dict]:
    resources = []
    seen_urls = set()
    seen_ids = set()
    while path:
        url = api_url(path)
        if url in seen_urls or len(seen_urls) >= 1000:
            raise RuntimeError("App Store Connect pagination repeated a page or exceeded its safety limit")
        seen_urls.add(url)
        response = json.loads(request("GET", url))
        page = response.get("data")
        if not isinstance(page, list):
            raise RuntimeError(f"App Store Connect returned an invalid resource list for {url}")
        for resource in page:
            identifier = resource.get("id") if isinstance(resource, dict) else None
            if not isinstance(identifier, str) or not identifier or identifier in seen_ids:
                raise RuntimeError("App Store Connect returned a missing or duplicate resource ID")
            seen_ids.add(identifier)
            resources.append(resource)
        path = response.get("links", {}).get("next")
        if path is not None and not isinstance(path, str):
            raise RuntimeError("App Store Connect returned an invalid pagination link")
    return resources


def list_certificates() -> list[dict]:
    return list_resources("/certificates?limit=200")


def preflight() -> None:
    if os.environ.get("PUBLISH_TESTFLIGHT") != "false":
        apps = list_resources("/apps?" + urllib.parse.urlencode({"filter[bundleId]": "plastickarma.otodo", "limit": 200}))
        if not any(app.get("attributes", {}).get("bundleId") == "plastickarma.otodo" for app in apps):
            raise RuntimeError("No accessible App Store Connect app record matches plastickarma.otodo")
    for _, identifier, _, _, _ in COMPONENTS:
        bundles = list_resources("/bundleIds?" + urllib.parse.urlencode({"filter[identifier]": identifier, "limit": 200}))
        matches = [bundle for bundle in bundles if bundle.get("attributes", {}).get("identifier") == identifier]
        if len(matches) != 1:
            raise RuntimeError(f"Expected one accessible Apple Bundle ID registration for {identifier}; found {len(matches)}")
        bundle_id = urllib.parse.quote(matches[0]["id"], safe="")
        capabilities = list_resources(f"/bundleIds/{bundle_id}/bundleIdCapabilities?limit=200")
        if not any(item.get("attributes", {}).get("capabilityType") == "APP_GROUPS" for item in capabilities):
            raise RuntimeError(f"Apple Bundle ID {identifier} does not have the App Groups capability enabled")
        print(f"Read-only Apple registration/capability access verified: {identifier}")
    print(
        "Preflight does not prove the named App Group assignment, cloud-distribution "
        "permission, current agreements, an open version train, or binary acceptance. "
        "Automatic signing and synchronous upload remain authoritative."
    )


def is_ephemeral_signing_certificate(certificate: dict) -> bool:
    attributes = certificate.get("attributes", {})
    certificate_type = attributes.get("certificateType")
    name = attributes.get("name", "")
    display_name = attributes.get("displayName", "")
    return certificate_type in EPHEMERAL_CERTIFICATE_TYPES and (
        name == "Created via API" or "Created via API" in display_name
    )


def certificate_fingerprint(certificate: dict) -> str | None:
    content = certificate.get("attributes", {}).get("certificateContent")
    if not isinstance(content, str) or not content:
        return None
    try:
        decoded = base64.b64decode(content, validate=True)
    except ValueError as error:
        raise RuntimeError("App Store Connect returned invalid certificate data") from error
    return hashlib.sha1(decoded).hexdigest().upper()


def revoke(certificate: dict) -> None:
    certificate_id = certificate.get("id")
    if not isinstance(certificate_id, str) or not certificate_id:
        raise RuntimeError("App Store Connect returned a certificate without an ID")
    attributes = certificate.get("attributes", {})
    print(
        "Revoking ephemeral signing certificate "
        f"{certificate_id} ({attributes.get('certificateType', 'unknown')})."
    )
    request("DELETE", f"/certificates/{urllib.parse.quote(certificate_id, safe='')}")


def prepare() -> None:
    snapshot_path = Path(required_environment("CERTIFICATE_SNAPSHOT"))
    bootstrap_fingerprint = os.environ.get(
        "BOOTSTRAP_CERTIFICATE_SHA1", ""
    ).replace(":", "").upper()
    certificates = list_certificates()

    if bootstrap_fingerprint:
        matches = [
            certificate
            for certificate in certificates
            if certificate_fingerprint(certificate) == bootstrap_fingerprint
        ]
        for certificate in matches:
            if not is_ephemeral_signing_certificate(certificate):
                raise RuntimeError(
                    "Refusing to revoke the bootstrap certificate because it is not "
                    "an API-created iOS signing certificate"
                )
            revoke(certificate)
        if matches:
            removed_ids = {certificate["id"] for certificate in matches}
            certificates = [
                certificate
                for certificate in certificates
                if certificate.get("id") not in removed_ids
            ]
            print(f"Revoked {len(matches)} orphaned bootstrap certificate(s).")
        else:
            print("The orphaned bootstrap certificate is already absent.")

    certificate_ids = sorted(certificate["id"] for certificate in certificates)
    snapshot_path.write_text(json.dumps({
        "run_id": required_environment("GITHUB_RUN_ID"),
        "before_ids": certificate_ids,
    }), encoding="utf-8")
    print(f"Recorded {len(certificate_ids)} certificate IDs before signing.")


def read_snapshot(path: Path) -> dict:
    snapshot = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(snapshot, dict) or snapshot.get("run_id") != required_environment("GITHUB_RUN_ID"):
        raise RuntimeError("Refusing a certificate snapshot from another release run")
    for key in ("before_ids", "created_ids"):
        if key not in snapshot and key == "created_ids":
            continue
        ids = snapshot.get(key)
        if (not isinstance(ids, list) or any(not isinstance(value, str) or not value for value in ids)
                or len(ids) != len(set(ids))):
            raise RuntimeError(f"Invalid certificate snapshot {key}; refusing cleanup")
    return snapshot


def capture() -> None:
    snapshot = read_snapshot(Path(required_environment("CERTIFICATE_SNAPSHOT")))
    before = set(snapshot["before_ids"])
    # Capture once, while this workflow still owns the global signing lock.
    # Cleanup retries must never compare an old baseline to a later catalogue.
    snapshot["created_ids"] = sorted(
        certificate["id"] for certificate in list_certificates()
        if certificate["id"] not in before and is_ephemeral_signing_certificate(certificate)
    )
    with Path(required_environment("CERTIFICATE_CLEANUP_PLAN")).open("x", encoding="utf-8") as destination:
        json.dump(snapshot, destination)
    print(f"Captured immutable cleanup allowlist of {len(snapshot['created_ids'])} certificate(s).")


def cleanup() -> None:
    snapshot = read_snapshot(Path(required_environment("CERTIFICATE_CLEANUP_PLAN")))
    if "created_ids" not in snapshot:
        raise RuntimeError("Missing immutable certificate cleanup allowlist; refusing a fresh before/after diff")
    before = set(snapshot["before_ids"])
    created = set(snapshot["created_ids"])
    if before & created:
        raise RuntimeError("Cleanup allowlist contains pre-existing certificate IDs; refusing revocation")
    if not created:
        print("No ephemeral certificates were created by this release.")
        return
    certificates = list_certificates()
    matches = [certificate for certificate in certificates if certificate["id"] in created]
    if any(not is_ephemeral_signing_certificate(certificate) for certificate in matches):
        raise RuntimeError("Cleanup allowlist includes a non-ephemeral signing certificate; refusing revocation")
    for certificate in matches:
        revoke(certificate)
    print(f"Revoked {len(matches)} allowlisted certificate(s); {len(created) - len(matches)} already absent.")


def main() -> None:
    commands = {"preflight": preflight, "prepare": prepare, "capture": capture, "cleanup": cleanup}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        raise RuntimeError("Usage: manage_api_certificates.py <preflight|prepare|capture|cleanup>")
    commands[sys.argv[1]]()


if __name__ == "__main__":
    try:
        main()
    except CommandError as error:
        annotate("error", str(error), title="Apple signing")
        raise SystemExit(error.returncode)
    except Exception as error:
        annotate("error", str(error), title="Apple signing")
        raise SystemExit(1)
