#!/usr/bin/env bash
# Regenerate patches/<component>/ from the commits on src/<component>'s
# macos-gl branch (upstream..macos-gl).
#
#   scripts/export-patches.sh [component...]
#
# Workflow: edit/commit/rebase inside src/<component>, then run this and commit
# the resulting patches/ changes in this repo.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

read -r -a selected <<<"$(select_components "$@")"

for c in "${selected[@]}"; do
    dir="$SRC/$c"
    [ -d "$dir/.git" ] || die "$c: src/$c missing; run scripts/fetch.sh $c first"
    git -C "$dir" rev-parse --verify --quiet "$PATCH_BRANCH" >/dev/null ||
        die "$c: no $PATCH_BRANCH branch in src/$c"
    [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] ||
        log "$c: warning: uncommitted changes in src/$c are not exported"

    out="$PATCHES/$c"
    mkdir -p "$out"
    rm -f "$out"/*.patch
    git -C "$dir" format-patch --quiet --zero-commit --no-signature \
        --output-directory "$out" upstream.."$PATCH_BRANCH"
    n=$(find "$out" -name '*.patch' | wc -l | tr -d ' ')
    log "$c: exported $n patch(es) to patches/$c/"
done
