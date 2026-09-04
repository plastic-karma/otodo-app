#!/usr/bin/env python3
"""Revoke only ephemeral certificates created by this release workflow."""

import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

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
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "Could not sign the App Store Connect token: "
            + result.stderr.decode("utf-8", errors="replace").strip()
        )
    signature = base64url(raw_es256_signature(result.stdout))
    return f"{header}.{payload}.{signature}"


def request(method: str, path: str) -> bytes:
    request_value = urllib.request.Request(
        f"{API_ROOT}{path}",
        method=method,
        headers={
            "Authorization": f"Bearer {authorization_token()}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request_value, timeout=30) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        response = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"App Store Connect {method} {path} failed with HTTP "
            f"{error.code}: {response}"
        ) from error


def list_certificates() -> list[dict]:
    response = json.loads(request("GET", "/certificates?limit=200"))
    certificates = response.get("data")
    if not isinstance(certificates, list):
        raise RuntimeError("App Store Connect returned an invalid certificate list")
    return certificates


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
    request("DELETE", f"/certificates/{urllib.parse.quote(certificate_id)}")


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

    certificate_ids = sorted(
        certificate["id"]
        for certificate in certificates
        if isinstance(certificate.get("id"), str)
    )
    snapshot_path.write_text(json.dumps(certificate_ids), encoding="utf-8")
    print(f"Recorded {len(certificate_ids)} certificate IDs before signing.")


def cleanup() -> None:
    snapshot_path = Path(required_environment("CERTIFICATE_SNAPSHOT"))
    if not snapshot_path.is_file():
        print("No signing certificate snapshot exists; cleanup is not required.")
        return
    before = set(json.loads(snapshot_path.read_text(encoding="utf-8")))
    certificates = list_certificates()
    created = [
        certificate
        for certificate in certificates
        if certificate.get("id") not in before
        and is_ephemeral_signing_certificate(certificate)
    ]
    for certificate in created:
        revoke(certificate)
    print(f"Revoked {len(created)} ephemeral certificate(s) created by this run.")


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in {"prepare", "cleanup"}:
        raise RuntimeError(
            "Usage: manage_api_certificates.py <prepare|cleanup>"
        )
    if sys.argv[1] == "prepare":
        prepare()
    else:
        cleanup()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)
