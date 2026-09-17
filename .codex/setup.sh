#!/usr/bin/env bash
set -euo pipefail

readonly GH_VERSION="2.101.0"
readonly XTOOL_VERSION="1.19.2"
readonly SWIFTLINT_VERSION="0.63.3"
readonly SWIFTFORMAT_VERSION="0.61.1"
readonly LOCAL_BIN="$HOME/.local/bin"
readonly PYTHON_ENV="$HOME/.cache/codex-ios/ci-python"
readonly XTOOL_ROOT="$HOME/.local/share/xtool/$XTOOL_VERSION"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
mkdir -p "$LOCAL_BIN" "$HOME/.cache/codex-ios" "$HOME/.local/share/xtool"
export PATH="$LOCAL_BIN:$PYTHON_ENV/bin:$PATH"

persisted_path='export PATH="$HOME/.local/bin:$HOME/.cache/codex-ios/ci-python/bin:$PATH"'
touch "$HOME/.bashrc"
if ! grep -Fqx "$persisted_path" "$HOME/.bashrc"; then
    printf '\n# Codex Cloud tools for Swift iOS repositories\n%s\n' "$persisted_path" >> "$HOME/.bashrc"
fi

case "$(uname -m)" in
    x86_64)
        gh_arch="amd64"
        gh_sha256="9bca2d1c16825f109907a23307628a2f0698fbf99662b73a5cf0b020293072b8"
        xtool_arch="x86_64"
        xtool_sha256="41c5adcfab3d8d65fba3db0b5885ae16cf9851560da724781be38e523fe4e3e7"
        swiftlint_archive="swiftlint_linux_amd64.zip"
        swiftlint_sha256="26db741d43f2f2dc26c0cf16911100a3e186c3d1dbb59e55ad3ac87b0de4538f"
        swiftformat_archive="swiftformat_linux.zip"
        swiftformat_member="swiftformat_linux"
        swiftformat_sha256="7bc8706e3fd51963f1f29eb99098ebdf482f3497fa527c68e6cf75cbee29c77a"
        ;;
    aarch64|arm64)
        gh_arch="arm64"
        gh_sha256="b57e8063f18862647c9d22727c32e9da1b963f8bf9db648fe123a6975695640f"
        xtool_arch="aarch64"
        xtool_sha256="83201c74365d6fcd7d0581d9854d7d13ad683ad6ca2fa921441086656a891455"
        swiftlint_archive="swiftlint_linux_arm64.zip"
        swiftlint_sha256="d5efcbed5ec1ca9eb7f833dfdd9f80f56289750b72582c7c1686b4528e182454"
        swiftformat_archive="swiftformat_linux_aarch64.zip"
        swiftformat_member="swiftformat_linux_aarch64"
        swiftformat_sha256="42a35b557a6d56975fba3a48e78d39ab5388c8faac65d4819f25d3e20c7504c0"
        ;;
    *)
        printf 'Unsupported Codex environment architecture: %s\n' "$(uname -m)" >&2
        exit 1
        ;;
esac

install_zip_binary() {
    local url="$1"
    local sha256="$2"
    local member="$3"
    local output="$4"
    local archive
    local temporary_directory
    archive="$(mktemp)"
    temporary_directory="$(mktemp -d)"
    curl --fail --silent --show-error --location --retry 3 --output "$archive" "$url"
    printf '%s  %s\n' "$sha256" "$archive" | sha256sum --check --status
    unzip -q "$archive" "$member" -d "$temporary_directory"
    install -m 0755 "$temporary_directory/$member" "$output"
    rm -rf "$archive" "$temporary_directory"
}
if [[ "$(gh --version 2>/dev/null | sed -n '1s/^gh version \([^ ]*\).*/\1/p')" != "$GH_VERSION" ]]; then
    archive="$(mktemp)"
    trap 'rm -f "$archive"' EXIT
    curl --fail --silent --show-error --location --retry 3 \
        --output "$archive" \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.tar.gz"
    printf '%s  %s\n' "$gh_sha256" "$archive" | sha256sum --check --status
    temporary_directory="$(mktemp -d)"
    tar -xzf "$archive" -C "$temporary_directory"
    install -m 0755 \
        "$temporary_directory/gh_${GH_VERSION}_linux_${gh_arch}/bin/gh" \
        "$LOCAL_BIN/gh"
    rm -rf "$temporary_directory"
fi

if [[ ! -x "$XTOOL_ROOT/squashfs-root/AppRun" ]]; then
    rm -rf "$XTOOL_ROOT"
    mkdir -p "$XTOOL_ROOT"
    app_image="$XTOOL_ROOT/xtool.AppImage"
    curl --fail --silent --show-error --location --retry 3 \
        --output "$app_image" \
        "https://github.com/xtool-org/xtool/releases/download/${XTOOL_VERSION}/xtool-${xtool_arch}.AppImage"
    printf '%s  %s\n' "$xtool_sha256" "$app_image" | sha256sum --check --status
    chmod +x "$app_image"
    (cd "$XTOOL_ROOT" && ./xtool.AppImage --appimage-extract >/dev/null)
fi
cat > "$LOCAL_BIN/xtool" <<EOF
#!/usr/bin/env bash
exec "$XTOOL_ROOT/squashfs-root/AppRun" "\$@"
EOF
chmod +x "$LOCAL_BIN/xtool"
if [[ -f .swiftlint.yml ]] && [[ "$(swiftlint version 2>/dev/null || true)" != "$SWIFTLINT_VERSION" ]]; then
    install_zip_binary \
        "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/${swiftlint_archive}" \
        "$swiftlint_sha256" \
        swiftlint-static \
        "$LOCAL_BIN/swiftlint"
fi

if [[ -f .swiftformat ]] && [[ "$(swiftformat --version 2>/dev/null || true)" != "$SWIFTFORMAT_VERSION" ]]; then
    install_zip_binary \
        "https://github.com/nicklockwood/SwiftFormat/releases/download/${SWIFTFORMAT_VERSION}/${swiftformat_archive}" \
        "$swiftformat_sha256" \
        "$swiftformat_member" \
        "$LOCAL_BIN/swiftformat"
fi

command -v python3 >/dev/null
command -v swift >/dev/null
python3 - <<'PY'
import sys
if sys.version_info < (3, 12):
    raise SystemExit(f"Python 3.12 or newer is required; found {sys.version.split()[0]}")
PY

python_command="python3"
if [[ -f .github/scripts/requirements.txt ]]; then
    if [[ ! -x "$PYTHON_ENV/bin/python3" ]]; then
        python3 -m venv "$PYTHON_ENV"
    fi
    "$PYTHON_ENV/bin/python3" -m pip install \
        --disable-pip-version-check \
        --requirement .github/scripts/requirements.txt
    python_command="$PYTHON_ENV/bin/python3"
fi

if [[ -f Package.swift ]]; then
    swift package resolve
fi
if ! git config --global --get init.defaultBranch >/dev/null; then
    git config --global init.defaultBranch main
fi
if ! git config --global --get user.name >/dev/null; then
    git config --global user.name "${CODEX_GIT_AUTHOR_NAME:-Codex}"
fi
if ! git config --global --get user.email >/dev/null; then
    git config --global user.email "${CODEX_GIT_AUTHOR_EMAIL:-codex@users.noreply.github.com}"
fi

gh --version
xtool --help >/dev/null
swift --version
if [[ -f .github/scripts/validate_bundles.py ]]; then
    "$python_command" .github/scripts/validate_bundles.py source
fi
printf 'Codex Cloud environment is ready for %s.\n' "$(basename "$repo_root")"
