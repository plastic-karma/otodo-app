#!/usr/bin/env bash
# Shared by setup and maintenance; run as the agent user, not with sudo bash.
# Sources: swift.org/install/linux/swiftly, xtool-org/xtool tag 1.19.2,
# swiftlang/swift-docker 6.3/ubuntu/24.04, cli/cli docs/install_linux.md.
set +x # Setup-only signed URLs must never appear in shell tracing.
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: bash .codex/setup.sh [--check | --help]

Installs Git, gh, Swift 6.3.3 and xtool 1.19.2 in Ubuntu 24.04 containers.
Setup and maintenance use the same idempotent implementation. --check only
checks installed tools and the Darwin SDK; it does not install anything.

Darwin SDK provisioning (choose one, only needed on the first setup):
  CODEX_XCODE_PATH          Absolute path to licensed Xcode 26 .xip or .app.
  CODEX_DARWIN_SDK_PATH     Absolute path to a darwin.xtoolsdk directory built
                           by xtool sdk build for this Linux architecture.
  CODEX_DARWIN_SDK_URL      Setup-only secret: private HTTPS URL to a tar.gz
                           with exactly one top-level darwin.xtoolsdk directory.
  CODEX_DARWIN_SDK_SHA256   Required SHA-256 of that private archive.

Build private SDKs with xtool sdk build Xcode.app OUTPUT --arch x86_64
(or --arch arm64 for aarch64), then archive OUTPUT/darwin.xtoolsdk.
Use only Apple software you are licensed to use; do not publish the SDK.
An installed SDK is reused. Reset the Codex cache to replace it.

For an explicitly Git/Linux-only environment, set CODEX_SKIP_DARWIN_SDK=1
in environment settings. This never reports iOS development as ready.
Setup-only secrets are NOT persisted. Git credentials and identity are NOT
configured. GitHub CLI authentication must be available in the agent phase;
a setup-only GH_TOKEN cannot authorize subsequent agent commands.
HELP
}

fail() { printf 'codex setup: %s\n' "$*" >&2; exit 1; }
case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --check) mode=check ;;
    '') mode=install ;;
    *) fail 'Unknown option; use --help.' ;;
esac
[[ $# -le 1 ]] || fail 'Expected at most one option.'
[[ "${CODEX_SKIP_DARWIN_SDK:-0}" =~ ^[01]$ ]] || fail 'CODEX_SKIP_DARWIN_SDK must be 0 or 1.'
[[ "$(uname -s)" == Linux ]] || fail 'This bootstrap requires Linux.'
arch=$(uname -m)
case "$arch" in x86_64|aarch64) ;; *) fail 'Supported architectures: x86_64 and aarch64.' ;; esac
# Codex universal is Ubuntu 24.04. Do not silently install incompatible packages.
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || fail 'Use an Ubuntu 24.04 Codex universal container.'

swift_version=6.3.3
xtool_version=1.19.2
xtool_root="/opt/codex-xtool/$xtool_version-$arch"

as_root() {
    if [[ $EUID == 0 ]]; then "$@"; else sudo -n "$@"; fi
}

check_tools() {
    git --version
    gh --version
    local version
    version=$(swift --version)
    [[ "$version" == "Swift version $swift_version "* ]] || fail 'Swift 6.3.3 is not selected on PATH.'
    printf '%s\n' "$version"
    sourcekit-lsp --help >/dev/null
    version=$(xtool --version)
    [[ "$version" == "xtool $xtool_version" ]] || fail 'xtool 1.19.2 is not selected on PATH.'
    printf '%s\n' "$version"
    xtool sdk --help >/dev/null
}

check_sdk() {
    local status bundle
    status=$(xtool sdk status)
    [[ "$status" == 'Installed at '* ]] || return 1
    bundle=${status#Installed at }
    [[ -d "$bundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs" ]] || return 1
    swift sdk configure darwin arm64-apple-ios --show-configuration >/dev/null || return 1
    # Prebuilt SDKs contain host-native tools despite listing both host triples.
    # Running the linker rejects an SDK accidentally built for the other CPU.
    "$bundle/toolset/bin/ld64.lld" --version >/dev/null || return 1
    printf 'Darwin SDK installed: %s\n' "$bundle"
}

if [[ "$mode" == check ]]; then
    check_tools
    if [[ "${CODEX_SKIP_DARWIN_SDK:-0}" == 1 ]]; then
        printf 'Darwin SDK explicitly disabled; iOS compilation is NOT configured.\n'
    else
        check_sdk || fail 'A usable Darwin SDK is missing; run setup with a licensed SDK source.'
    fi
    exit 0
fi

# No Git config, remotes, credential helpers, Apple login or repository edits.
# Keep Swiftly operations outside the checkout so .swift-version is never written.
cd "$HOME"
work=$(mktemp -d "${TMPDIR:-/tmp}/codex-ios-setup.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

packages=(ca-certificates curl git gnupg2 python3 binutils unzip zip libc6-dev
    libcurl4-openssl-dev libedit2 libgcc-13-dev libpython3-dev libsqlite3-0
    libstdc++-13-dev libxml2-dev libncurses-dev libz3-dev pkg-config tzdata zlib1g-dev)
missing=()
for package in "${packages[@]}"; do
    if [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" != 'install ok installed' ]]; then
        missing+=("$package")
    fi
done
if ((${#missing[@]})); then
    as_root apt-get update
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
fi

# Ubuntu's older community gh packages use deprecated APIs. Use the official repo.
if [[ ! -f /etc/apt/sources.list.d/github-cli.list ]]; then
    curl --fail --silent --show-error --location --proto '=https' \
        https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$work/gh-keyring.gpg"
    printf '%s  %s\n' 6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b "$work/gh-keyring.gpg" | sha256sum --check --status
    as_root install -d -m 755 /etc/apt/keyrings /etc/apt/sources.list.d
    as_root install -m 644 "$work/gh-keyring.gpg" /etc/apt/keyrings/githubcli-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
        "$(dpkg --print-architecture)" > "$work/gh.list"
    as_root install -m 644 "$work/gh.list" /etc/apt/sources.list.d/github-cli.list
    as_root apt-get update
fi
as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh

# Reuse universal's Swiftly, including its persistent SWIFTLY_BIN_DIR/PATH.
# Standalone Ubuntu containers use the documented Swiftly install layout.
if ! command -v swiftly >/dev/null; then
    url="https://download.swift.org/swiftly/linux/swiftly-1.1.2-$arch.tar.gz"
    curl --fail --silent --show-error --location --proto '=https' "$url" -o "$work/swiftly.tar.gz"
    curl --fail --silent --show-error --location --proto '=https' "$url.sig" -o "$work/swiftly.tar.gz.sig"
    curl --fail --silent --show-error --location --proto '=https' https://www.swift.org/keys/all-keys.asc -o "$work/swift-keys.asc"
    mkdir -m 700 "$work/gnupg"
    gpg --homedir "$work/gnupg" --batch --quiet --import "$work/swift-keys.asc"
    gpg --homedir "$work/gnupg" --batch --verify "$work/swiftly.tar.gz.sig" "$work/swiftly.tar.gz"
    tar -xzf "$work/swiftly.tar.gz" -C "$work"
    "$work/swiftly" init --assume-yes --skip-install --no-modify-profile --quiet-shell-followup
    source "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
fi
swiftly install "$swift_version" --assume-yes
swiftly use "$swift_version" --global-default --assume-yes
# Durable discovery: symlinks work in fresh non-login agent shells without exports.
as_root install -d -m 755 /usr/local/bin
swiftly_bin=$(dirname "$(command -v swiftly)")
for tool in "$swiftly_bin"/*; do
    [[ -x "$tool" && ! -d "$tool" ]] || continue
    [[ "$tool" == /usr/local/bin/* ]] || as_root ln -sfn "$tool" "/usr/local/bin/$(basename "$tool")"
done

if [[ ! -x "$xtool_root/AppRun" ]]; then
    curl --fail --silent --show-error --location --proto '=https' \
        "https://github.com/xtool-org/xtool/releases/download/$xtool_version/xtool-$arch.AppImage" -o "$work/xtool.AppImage"
    chmod +x "$work/xtool.AppImage"
    # Upstream's container recipe extracts once; no FUSE or repeated extraction.
    (cd "$work" && ./xtool.AppImage --appimage-extract >/dev/null)
    [[ -x "$work/squashfs-root/AppRun" ]] || fail 'The xtool release did not contain AppRun.'
    as_root install -d -m 755 "$(dirname "$xtool_root")"
    as_root mv "$work/squashfs-root" "$xtool_root"
fi
as_root ln -sfn "$xtool_root/AppRun" /usr/local/bin/xtool
hash -r
check_tools

if [[ "${CODEX_SKIP_DARWIN_SDK:-0}" == 1 ]]; then
    printf 'Darwin SDK explicitly disabled; Git/Linux tooling installed, iOS compilation is NOT configured.\n'
    exit 0
fi
if ! check_sdk; then
    sources=0
    for source in CODEX_XCODE_PATH CODEX_DARWIN_SDK_PATH CODEX_DARWIN_SDK_URL; do
        [[ -z "${!source:-}" ]] || sources=$((sources + 1))
    done
    [[ $sources == 1 ]] || fail 'Set exactly one licensed SDK source; use --help for prerequisites. No iOS-ready fallback is provided.'
    sdk_source=${CODEX_XCODE_PATH:-${CODEX_DARWIN_SDK_PATH:-}}
    if [[ -n "${CODEX_DARWIN_SDK_URL:-}" ]]; then
        [[ "$CODEX_DARWIN_SDK_URL" == https://* && "$CODEX_DARWIN_SDK_URL" != *$'\n'* && "$CODEX_DARWIN_SDK_URL" != *$'\r'* ]] || fail 'The private SDK URL must be single-line HTTPS.'
        [[ "${CODEX_DARWIN_SDK_SHA256:-}" =~ ^[a-fA-F0-9]{64}$ ]] || fail 'Set CODEX_DARWIN_SDK_SHA256 to the archive checksum.'
        # Pass the signed URL through stdin, never argv, disk, tracing or errors.
        private_url=${CODEX_DARWIN_SDK_URL//\\/\\\\}
        private_url=${private_url//\"/\\\"}
        if ! printf 'url = "%s"\n' "$private_url" | curl --config - --fail --silent --location \
            --proto '=https' --proto-redir '=https' -o "$work/sdk.tar.gz"; then
            fail 'Private SDK download failed; refresh its setup-only URL secret.'
        fi
        unset private_url CODEX_DARWIN_SDK_URL
        printf '%s  %s\n' "$CODEX_DARWIN_SDK_SHA256" "$work/sdk.tar.gz" | sha256sum --check --status
        mkdir "$work/sdk"
        python3 - "$work/sdk.tar.gz" "$work/sdk" <<'PY'
import sys
import tarfile
with tarfile.open(sys.argv[1], "r:gz") as archive:
    archive.extractall(sys.argv[2], filter="data")
PY
        sdk_source="$work/sdk/darwin.xtoolsdk"
        [[ -d "$sdk_source" ]] || fail 'The archive must contain a top-level darwin.xtoolsdk directory.'
    fi
    [[ "$sdk_source" == /* && -e "$sdk_source" ]] || fail 'The SDK source must be an existing absolute path.'
    xtool sdk install "$sdk_source" </dev/null
    check_sdk || fail 'SDK installation did not produce a usable native Darwin toolchain.'
fi
printf 'Tooling installed. GitHub and Apple authentication were intentionally left unchanged.\n'
