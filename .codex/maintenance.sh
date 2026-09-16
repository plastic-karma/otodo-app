#!/usr/bin/env bash
# Cached containers need the same pinned tooling and SDK checks as fresh ones.
set -euo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/setup.sh" "$@"
