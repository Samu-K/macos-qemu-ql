# shellcheck shell=bash
# Variables here are used by the scripts that source this file.
# shellcheck disable=SC2034
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

# Order matters: each component builds against the ones before it.
COMPONENTS=(angle libepoxy virglrenderer qemu)

# Branch in src/<component> that carries our patches on top of the pinned ref.
PATCH_BRANCH=macos-gl

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Upper-cased variable prefix for a component: virglrenderer -> VIRGLRENDERER
var_prefix() { echo "$1" | tr '[:lower:]-' '[:upper:]_'; }
component_url() { local v; v="$(var_prefix "$1")_URL"; echo "${!v}"; }
component_ref() { local v; v="$(var_prefix "$1")_REF"; echo "${!v}"; }

# Components given on the command line, or all of them.
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
