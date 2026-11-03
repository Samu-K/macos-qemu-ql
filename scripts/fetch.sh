#!/usr/bin/env bash
# Fetch pinned upstream sources into src/<component> and apply our patches.
#
#   scripts/fetch.sh [--reset] [component...]
#
# Each src/<component> is a shallow git checkout with two branches:
#   upstream   the pinned ref from versions.env, untouched
#   macos-gl   upstream + patches/<component>/*.patch (checked out)
#
# Without --reset an existing checkout is left alone if it is already on the
# pinned ref, so local work in progress is never thrown away. --reset discards
# local commits/changes and re-applies patches/ from scratch.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

reset=0
if [ "${1:-}" = --reset ]; then
    reset=1
    shift
fi

# git am needs a committer identity; the patch authors are preserved.
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-macos-qemu-gl}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-macos-qemu-gl@localhost}"

fetch_depot_tools() {
    local dir="$SRC/depot_tools"
    if [ ! -d "$dir/.git" ]; then
        log "depot_tools: cloning"
        git clone --quiet --depth 1 --branch "$DEPOT_TOOLS_REF" "$DEPOT_TOOLS_URL" "$dir"
    fi
}

# Shallow-fetch the pinned ref into branch `upstream`.
fetch_upstream() {
    local c="$1" dir="$SRC/$1" url ref
    url="$(component_url "$c")"
    ref="$(component_ref "$c")"

    if [ ! -d "$dir/.git" ]; then
        log "$c: cloning $ref"
        mkdir -p "$dir"
        git -C "$dir" init --quiet
        git -C "$dir" remote add origin "$url"
    fi

    local want
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        want="$ref"
    else
        want="refs/tags/$ref"
    fi

    if git -C "$dir" rev-parse --verify --quiet upstream >/dev/null &&
       [ "$(git -C "$dir" config --get macos-gl.pinned || true)" = "$ref" ]; then
        return 0
    fi

    log "$c: fetching $ref"
    git -C "$dir" fetch --quiet --depth 1 --no-tags origin "$want"
    git -C "$dir" branch --force upstream FETCH_HEAD
    git -C "$dir" config macos-gl.pinned "$ref"
    force=1  # new pin: patches must be re-applied
}

apply_patches() {
    local c="$1" dir="$SRC/$1"
    local patches=("$PATCHES/$c"/*.patch)

    if [ "$force" -eq 0 ] &&
       [ "$(git -C "$dir" symbolic-ref --quiet --short HEAD || true)" = "$PATCH_BRANCH" ]; then
        log "$c: $PATCH_BRANCH already checked out (use --reset to re-apply patches)"
        return 0
    fi

    git -C "$dir" am --abort >/dev/null 2>&1 || true
    git -C "$dir" checkout --quiet --force -B "$PATCH_BRANCH" upstream
    # No -x: keep ignored files (ANGLE's gclient-synced third_party, build output).
    git -C "$dir" clean --quiet -fd

    if [ -e "${patches[0]}" ]; then
        log "$c: applying ${#patches[@]} patch(es)"
        git -C "$dir" am --quiet --3way "${patches[@]}" ||
            die "$c: patch failed to apply; resolve in src/$c (git am --continue), then run scripts/export-patches.sh $c"
    else
        log "$c: no patches"
    fi
}

sync_angle() (
    local dir="$SRC/angle"
    # depot_tools only on PATH here: its ninja/gn wrappers would shadow the
    # real tools for the other builds.
    export DEPOT_TOOLS_UPDATE=0
    export PATH="$SRC/depot_tools:$PATH"
    log "angle: syncing third-party dependencies (large download on first run)"
    # Same as ANGLE's scripts/bootstrap.py, minus dependencies that only the
    # backends/tests we don't build need (~7 GB): OpenCL (LLVM sources),
    # WebGPU (Dawn), Vulkan (SwiftShader, conformance tests), perf tooling.
    cat >"$dir/.gclient" <<'GCLIENT'
solutions = [
  {
    "name": ".",
    "url": "https://chromium.googlesource.com/angle/angle.git",
    "deps_file": "DEPS",
    "managed": False,
    "custom_vars": {
      "checkout_angle_cl_deps": False,
      "checkout_angle_dawn_deps": False,
    },
    "custom_deps": {
      "third_party/SwiftShader": None,
      "third_party/VK-GL-CTS/src": None,
      "third_party/catapult": None,
    },
  },
]
GCLIENT
    (cd "$dir" && gclient sync --no-history --shallow -D)
)

mkdir -p "$SRC"
read -r -a selected <<<"$(select_components "$@")"

fetch_component() {
    local c="$1"
    local force=$reset  # seen by fetch_upstream/apply_patches (dynamic scope)

    if [ "$c" = angle ]; then
        fetch_depot_tools
    fi
    fetch_upstream "$c"
    apply_patches "$c"
    if [ "$c" = angle ]; then
        sync_angle
    fi
}

for c in "${selected[@]}"; do
    fetch_component "$c"
done
