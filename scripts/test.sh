#!/usr/bin/env bash
# Test the build installed in $PREFIX (default: prefix/), or a package made
# by scripts/package.sh.
#
#   scripts/test.sh [test...]
#   scripts/test.sh --package dist/<name>-macos-arm64.tar.xz [test...]
#
# Tests: version linkage features qemu-img boot-es boot-on bundle. The default
# is all of them; bundle (the package is self-contained) only with --package,
# which unpacks the tarball into a temporary directory and tests that.
#
# The boot tests start qemu-system-aarch64 with virtio-gpu-gl-pci and the Cocoa
# display (gl=es / gl=on), boot the bundled EDK2 firmware to its UEFI shell and
# check that QEMU initialised the GL path without errors. They open a window
# for a few seconds.
#
# Environment:
#   TEST_ACCEL    accelerator (default: hvf if the host supports it, else tcg;
#                 GitHub's macOS runners are VMs without nested virtualization)
#   TEST_TIMEOUT  seconds to wait for each boot (default: 180)

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

package=
if [ "${1:-}" = --package ]; then
    [ $# -ge 2 ] || die "usage: scripts/test.sh --package <tarball> [test...]"
    package="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    [ -f "$package" ] || die "$2 not found"
    shift 2
fi

if [ -z "${TEST_ACCEL:-}" ]; then
    if [ "$(sysctl -n kern.hv_support 2>/dev/null)" = 1 ]; then
        TEST_ACCEL=hvf
    else
        TEST_ACCEL=tcg
    fi
fi
# Under TCG, -cpu max emulates pointer authentication with the slow QARMA
# algorithm; pauth-impdef keeps the feature but makes firmware boot much faster.
if [ "$TEST_ACCEL" = hvf ]; then
    TEST_CPU=host
else
    TEST_CPU=max,pauth-impdef=on
fi
TEST_TIMEOUT="${TEST_TIMEOUT:-180}"
ALL_TESTS=(version linkage features qemu-img boot-es boot-on bundle)

BINARIES=(qemu-system-aarch64 qemu-system-x86_64 qemu-img)

# Libraries the binaries may link besides macOS itself (dependency policy in
# CLAUDE.md): our GL stack, plus these from Homebrew.
ALLOWED_OWN_LIBS='libepoxy|libvirglrenderer'
ALLOWED_BREW_LIBS='libglib-2\.0|libpixman-1|libslirp|libzstd'

failures=()
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures+=("$*"); }

# Unix socket paths are limited to 104 bytes on macOS, so keep this short.
TMP="$(mktemp -d /tmp/qgl.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "$package" ]; then
    mkdir "$TMP/pkg"
    tar -xJf "$package" -C "$TMP/pkg"
    PREFIX="$(echo "$TMP"/pkg/*)"
    [ -d "$PREFIX/bin" ] || die "$package doesn't contain a single top-level directory with bin/"
fi
QEMU="$PREFIX/bin/qemu-system-aarch64"

test_version() {
    local want="${QEMU_REF#v}" got
    got="$("$QEMU" --version | head -1)"
    if [[ "$got" == *"version $want"* ]]; then
        pass "qemu reports version $want"
    else
        fail "expected version $want, got: $got"
    fi
}

# Non-system libraries a Mach-O file links against.
external_libs() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/)' || true
}

test_linkage() {
    local file lib name ok=1
    for file in "${BINARIES[@]/#/$PREFIX/bin/}" "$PREFIX/lib/libepoxy.0.dylib" "$PREFIX/lib/libvirglrenderer.1.dylib"; do
        while read -r lib; do
            [ -n "$lib" ] || continue
            name="$(basename "$lib")"
            if [[ "$name" =~ ^($ALLOWED_OWN_LIBS)\. ]] &&
               [[ "$lib" == "$PREFIX/lib/"* || "$lib" == @rpath/* || "$lib" == @loader_path/* ]]; then
                continue
            fi
            if [[ "$name" =~ ^($ALLOWED_BREW_LIBS)\. ]]; then
                continue
            fi
            # A library's own install name is listed first; that's fine.
            [ "$name" = "$(basename "$file")" ] && continue
            fail "$(basename "$file") links $lib, which the dependency policy doesn't allow"
            ok=0
        done < <(external_libs "$file")
    done
    if [ $ok -eq 1 ]; then
        pass "binaries link only allowed libraries"
    fi
}

test_features() {
    "$QEMU" -device help 2>&1 | grep -q '"virtio-gpu-gl-pci"' &&
        pass "virtio-gpu-gl-pci device available" ||
        fail "virtio-gpu-gl-pci device missing"
    "$QEMU" -display help 2>&1 | grep -qx 'cocoa' &&
        pass "cocoa display available" ||
        fail "cocoa display missing"
    "$QEMU" -h 2>&1 | grep -q -- '-display cocoa.*gl=on|core|es|off' &&
        pass "cocoa display accepts gl=on|core|es" ||
        fail "cocoa display has no gl option"
    "$QEMU" -accel help 2>&1 | grep -qx 'hvf' &&
        pass "hvf accelerator built in" ||
        fail "hvf accelerator missing"
}

test_qemu_img() {
    local fmt img="$PREFIX/bin/qemu-img"
    for fmt in qcow2 raw vmdk vhdx vpc vdi; do
        if "$img" create -q -f "$fmt" "$TMP/t.$fmt" 16M &&
           "$img" info "$TMP/t.$fmt" | grep -q "file format: $fmt"; then
            pass "qemu-img creates $fmt"
        else
            fail "qemu-img cannot create $fmt"
        fi
    done
}

# boot_test <gl mode>
boot_test() {
    local gl="$1" dir="$TMP/boot-$1" pid waited=0 status
    mkdir -p "$dir"

    # -nodefaults: no default NIC, whose PXE/HTTP boot attempts would delay
    # the firmware shell by minutes under TCG.
    "$QEMU" -M virt -nodefaults -accel "$TEST_ACCEL" -cpu "$TEST_CPU" -m 512M \
        -bios "$PREFIX/share/qemu/edk2-aarch64-code.fd" \
        -device virtio-gpu-gl-pci -display "cocoa,gl=$gl" \
        -serial "file:$dir/serial" -monitor none \
        -qmp "unix:$dir/qmp,server=on,wait=off" \
        >"$dir/stdout" 2>"$dir/stderr" &
    pid=$!

    until grep -q 'Shell>' "$dir/serial" 2>/dev/null; do
        if ! kill -0 $pid 2>/dev/null; then
            break
        fi
        if [ $waited -ge "$TEST_TIMEOUT" ]; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if ! kill -0 $pid 2>/dev/null; then
        status=0
        wait $pid || status=$?
        fail "gl=$gl: qemu exited early (status $status)"
        sed 's/^/      /' "$dir/stderr" | head -20
        return
    fi

    if grep -q 'Shell>' "$dir/serial"; then
        pass "gl=$gl: firmware reached the UEFI shell (${waited}s)"
    else
        fail "gl=$gl: no UEFI shell after ${TEST_TIMEOUT}s"
        tr -d '\r' <"$dir/serial" | tail -5 | sed 's/^/      /'
    fi

    local opts
    opts="$(python3 "$ROOT/scripts/qmp.py" "$dir/qmp" query-display-options || true)"
    if [[ "$opts" == *"\"gl\": \"$gl\""* ]]; then
        pass "gl=$gl: display reports gl=$gl"
    else
        fail "gl=$gl: unexpected display options: $opts"
    fi

    if [ "$gl" = es ] && command -v vmmap >/dev/null; then
        # Capture first: grep -q exiting early would SIGPIPE vmmap (pipefail).
        vmmap "$pid" >"$dir/vmmap" 2>/dev/null || true
        if grep -q "$PREFIX/lib/libEGL.dylib" "$dir/vmmap"; then
            pass "gl=es: ANGLE loaded from $PREFIX/lib"
        else
            fail "gl=es: ANGLE's libEGL.dylib not loaded from $PREFIX/lib"
        fi
    fi

    python3 "$ROOT/scripts/qmp.py" "$dir/qmp" quit >/dev/null || kill $pid 2>/dev/null
    status=0
    wait $pid || status=$?
    if [ $status -eq 0 ]; then
        pass "gl=$gl: clean shutdown"
    else
        fail "gl=$gl: qemu exit status $status"
    fi

    if [ -s "$dir/stderr" ]; then
        fail "gl=$gl: qemu wrote to stderr"
        sed 's/^/      /' "$dir/stderr" | head -20
    else
        pass "gl=$gl: no errors on stderr"
    fi
}

test_boot_es() { boot_test es; }
test_boot_on() { boot_test on; }

# The package runs from wherever it is unpacked: every non-system library is
# inside it and linked via @rpath, signatures are intact, and QEMU looks for
# firmware in the package.
test_bundle() {
    local f lib rp ok=1
    for f in "$PREFIX"/bin/* "$PREFIX"/lib/*.dylib; do
        file -b "$f" | grep -q '^Mach-O' || continue
        while read -r lib; do
            [ -n "$lib" ] || continue
            if [[ "$lib" != @rpath/* ]] || [ ! -f "$PREFIX/lib/${lib#@rpath/}" ]; then
                fail "$(basename "$f") links $lib, which isn't bundled"
                ok=0
            fi
        done < <(external_libs "$f")
        while read -r rp; do
            case "$rp" in
                @loader_path|@executable_path/../lib) ;;
                *) fail "$(basename "$f") has rpath $rp"; ok=0 ;;
            esac
        done < <(otool -l "$f" | awk '/cmd LC_RPATH/ {r=1} r && $1 == "path" {print $2; r=0}')
        if ! codesign --verify --strict "$f" 2>/dev/null; then
            fail "$(basename "$f") has an invalid code signature"
            ok=0
        fi
    done
    if [ $ok -eq 1 ]; then
        pass "all libraries bundled and linked via @rpath, signatures valid"
    fi

    codesign -d --entitlements - "$QEMU" 2>/dev/null | grep -q com.apple.security.hypervisor &&
        pass "qemu-system-aarch64 keeps the hypervisor entitlement" ||
        fail "qemu-system-aarch64 lost the hypervisor entitlement"

    # QEMU reports the physical path (/tmp is a symlink to /private/tmp).
    "$QEMU" -L help | grep -qxF "$(cd -P "$PREFIX" && pwd)/bin/../share/qemu" &&
        pass "firmware is looked up in the package" ||
        fail "firmware search path is outside the package: $("$QEMU" -L help | tr '\n' ' ')"

    # What gl=es actually loaded, including ANGLE via dlopen (from boot-es).
    if [ -f "$TMP/boot-es/vmmap" ]; then
        local outside
        outside="$(grep -oE '(/opt/homebrew|/usr/local|'"$ROOT"')/[^ ]+' "$TMP/boot-es/vmmap" | sort -u || true)"
        if [ -z "$outside" ]; then
            pass "gl=es: nothing loaded from Homebrew or the build tree"
        else
            fail "gl=es: loaded files from outside the package: $(echo "$outside" | tr '\n' ' ')"
        fi
    fi
}

[ -x "$QEMU" ] || die "$QEMU not found; run scripts/build.sh first"

tests=("$@")
if [ ${#tests[@]} -eq 0 ]; then
    tests=("${ALL_TESTS[@]}")
    [ -n "$package" ] || tests=("${tests[@]/bundle}")
fi

log "accelerator: $TEST_ACCEL, cpu: $TEST_CPU"
[ -z "$package" ] || log "package: $(basename "$package")"
for t in "${tests[@]}"; do
    [ -n "$t" ] || continue
    [[ " ${ALL_TESTS[*]} " == *" $t "* ]] || die "unknown test: $t (expected: ${ALL_TESTS[*]})"
    log "test: $t"
    "test_${t//-/_}"
done

echo
if [ ${#failures[@]} -eq 0 ]; then
    log "all tests passed"
else
    printf '\033[1;31m%d failure(s):\033[0m\n' "${#failures[@]}" >&2
    printf '  - %s\n' "${failures[@]}" >&2
    exit 1
fi
