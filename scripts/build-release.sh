#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
xtool="${XTOOL:-xtool}"
if ! command -v -- "$xtool" >/dev/null 2>&1; then
    printf 'xtool is not installed; add it to PATH or set XTOOL to its executable.\n' >&2
    exit 127
fi
exec "$xtool" release --config "$repo/xtool-release.yml" "$@"
