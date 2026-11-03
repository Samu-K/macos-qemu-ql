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
