#!/usr/bin/env bash
# CI entry point: fetch, build, test, package and test the package from
# scratch, one log per stage.
#
#   scripts/ci.sh
#
# Logs go to $LOG_DIR (default: logs/<stage>.log). When a stage fails, its
# name is written to $LOG_DIR/failed-stage and the script exits non-zero.
#
# Environment:
#   CI_SOURCE_ARCHIVE=1  also write the source archive (scripts/package.sh --source)
#   PACKAGE_VERSION, SIGN_IDENTITY, NOTARY_*
#                        passed on to scripts/package.sh (and SIGN_IDENTITY to test.sh)

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

LOG_DIR="${LOG_DIR:-$ROOT/logs}"
mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR/failed-stage"

group()    { [ -z "${GITHUB_ACTIONS:-}" ] || echo "::group::$*"; }
endgroup() { [ -z "${GITHUB_ACTIONS:-}" ] || echo "::endgroup::"; }

# run_stage <name> <command...>
run_stage() {
    local name="$1"
    shift
    group "$name"
    if "$@" 2>&1 | tee "$LOG_DIR/$name.log"; then
        endgroup
        return 0
    fi
    endgroup
    echo "$name" >"$LOG_DIR/failed-stage"
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::error title=$name failed::see $name.log in the logs artifact"
    die "stage '$name' failed; log: $LOG_DIR/$name.log"
}

run_stage fetch scripts/fetch.sh --reset
run_stage build scripts/build.sh
run_stage test scripts/test.sh

package_args=()
[ -z "${CI_SOURCE_ARCHIVE:-}" ] || package_args+=(--source)
rm -rf "$DIST"
run_stage package scripts/package.sh ${package_args[@]+"${package_args[@]}"}
tarballs=("$DIST"/*-macos-arm64.tar.xz)
run_stage test-package scripts/test.sh --package "${tarballs[0]}"
log "all stages passed: $(basename "${tarballs[0]}")"
