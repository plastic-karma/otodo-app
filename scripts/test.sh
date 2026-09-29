#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --apple ) ]]; then
    printf 'Usage: scripts/test.sh [--apple]\n' >&2
    exit 2
fi
if [[ ${1:-} == --apple && $(uname -s) != Darwin ]]; then
    printf 'Apple tests require a local Mac with Xcode, XcodeGen, and installed iOS/watchOS simulators. No Apple tests ran.\n' >&2
    exit 1
fi
python="${PYTHON:-$repo/.build/local-python/bin/python3}"
if [[ -z ${PYTHON:-} && ! -x "$python" ]]; then python=python3; fi
if ! "$python" -c 'import yaml' >/dev/null 2>&1; then
    printf 'Python with scripts/requirements.txt is required. Run ./.codex/setup.sh or set PYTHON to your prepared interpreter.\n' >&2
    exit 1
fi
"$python" scripts/validate_bundles.py source
"$python" -m unittest discover -s scripts -p 'test_*.py'
swift test
if [[ ${1:-} == --apple ]]; then
    exec "$python" scripts/apple_tests.py
fi
