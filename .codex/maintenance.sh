#!/usr/bin/env bash
set -euo pipefail

# Reconcile cached tools and dependencies with the branch selected for this chat.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup.sh"
