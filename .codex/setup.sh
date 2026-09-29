#!/usr/bin/env bash
set -euo pipefail
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
command -v swift >/dev/null
python="${PYTHON:-python3}"
"$python" - <<'PY'
import sys
if sys.version_info < (3, 12):
    raise SystemExit(f"Python 3.12 or newer is required; found {sys.version.split()[0]}")
PY
venv="$repo/.build/local-python"
if [[ ! -x "$venv/bin/python3" ]]; then
    "$python" -m venv "$venv"
fi
"$venv/bin/python3" -m pip install --disable-pip-version-check --requirement scripts/requirements.txt
swift package resolve
printf 'Local dependencies are ready. Run scripts/test.sh (or scripts/test.sh --apple on a Mac).\n'
printf 'Install native xtool separately for scripts/build-release.sh; no global tools or credentials were changed.\n'
