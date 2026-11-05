# shellcheck shell=bash disable=SC2034
# Shared setup for scripts/*.sh. Source, don't execute.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../versions.env
source "$ROOT/versions.env"

SRC="$ROOT/src"
BUILD="$ROOT/build"
PREFIX="${PREFIX:-$ROOT/prefix}"
PATCHES="$ROOT/patches"
DIST="$ROOT/dist"

# Binary package name and where it is published.
PACKAGE_NAME=macos-qemu-gl
PROJECT_URL=https://github.com/Samu-K/macos-qemu-ql

# Build order.
COMPONENTS=(angle libepoxy virglrenderer qemu)

PATCH_BRANCH=macos-gl

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

var_prefix() { echo "$1" | tr '[:lower:]-' '[:upper:]_'; }
component_url() { local v; v="$(var_prefix "$1")_URL"; echo "${!v}"; }
component_ref() { local v; v="$(var_prefix "$1")_REF"; echo "${!v}"; }

select_components() {
    if [ $# -eq 0 ]; then
        echo "${COMPONENTS[@]}"
        return
    fi
    local c
    for c in "$@"; do
        [[ " ${COMPONENTS[*]} " == *" $c "* ]] || die "unknown component: $c (expected: ${COMPONENTS[*]})"
    done
    echo "$@"
}

# ANGLE needs full Xcode; fall back to it when the active developer dir is the CLT.
use_xcode() {
    if xcodebuild -version >/dev/null 2>&1; then
        return 0
    fi
    local xcode="${XCODE_APP:-/Applications/Xcode.app}/Contents/Developer"
    [ -d "$xcode" ] || die "ANGLE needs full Xcode; install it or set XCODE_APP=/path/to/Xcode.app"
    export DEVELOPER_DIR="$xcode"
    xcodebuild -version >/dev/null 2>&1 ||
        die "xcodebuild failed; accept the license with: sudo xcodebuild -license"
    xcrun --find metal >/dev/null 2>&1 && xcrun metal --version >/dev/null 2>&1 ||
        die "Metal toolchain missing; run: xcodebuild -downloadComponent MetalToolchain"
}
