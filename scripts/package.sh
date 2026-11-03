#!/usr/bin/env bash
# Package the build in $PREFIX (default: prefix/) as a self-contained,
# relocatable tarball for Apple Silicon Macs.
#
#   scripts/package.sh [--source]
#
# Output in dist/:
#   <name>-<version>-macos-arm64.tar.xz (+ .sha256)
#       QEMU, the GL stack and the Homebrew libraries it links (glib, pixman,
#       libslirp, zstd and their dependencies), with install names rewritten
#       to @rpath, so it runs from any directory without Homebrew. Every
#       binary is re-signed with the hardened runtime. Includes all licenses.
#   <name>-<version>-source.tar (with --source)
#       Corresponding source for a binary release: this repository (build
#       scripts and patches), the QEMU release tarball, and the upstream
#       sources of virglrenderer, libepoxy and the bundled Homebrew libraries.
#
# Environment:
#   PACKAGE_VERSION  version in the file names (default: <qemu version>-g<commit>,
#                    plus -dirty when this repository has uncommitted changes)
#   SIGN_IDENTITY    codesign identity (default: - for ad hoc). With a
#                    "Developer ID Application: ..." identity the package is
#                    signed for distribution and notarized, given credentials:
#   NOTARY_PROFILE   notarytool keychain profile (xcrun notarytool store-credentials), or
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                    App Store Connect API key file (.p8), its ID and issuer ID
#
# Test the result with: scripts/test.sh --package dist/<name>-<version>-macos-arm64.tar.xz

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

with_source=0
if [ "${1:-}" = --source ]; then
    with_source=1
    shift
fi
[ $# -eq 0 ] || die "usage: scripts/package.sh [--source]"

QEMU_VERSION="${QEMU_REF#v}"
if [ -z "${PACKAGE_VERSION:-}" ]; then
    PACKAGE_VERSION="$QEMU_VERSION-g$(git -C "$ROOT" rev-parse --short HEAD)"
    [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || PACKAGE_VERSION+=-dirty
fi
PKG="$PACKAGE_NAME-$PACKAGE_VERSION"
STAGE="$BUILD/package/$PKG"
TARBALL="$DIST/$PKG-macos-arm64.tar.xz"
ORIGINS="$BUILD/package/$PKG.origins"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
notarized=0

[ -x "$PREFIX/bin/qemu-system-aarch64" ] || die "$PREFIX has no QEMU; run scripts/build.sh first"

# Firmware that only QEMU targets outside $QEMU_TARGETS (aarch64, x86_64) use.
# QEMU installs firmware for every architecture regardless of the target list.
OTHER_ARCH_FIRMWARE=(
    'dtb'                          # ppc, microblaze device trees
    'edk2-loongarch64-*' 'firmware/*-edk2-loongarch64.json'
    'edk2-riscv-*' 'firmware/*-edk2-riscv64.json' 'opensbi-*'
    'hppa-firmware*'
    'openbios-*' 'QEMU,cgthree.bin' 'QEMU,tcx.bin'   # sparc, ppc
    'palcode-clipper'              # alpha
    'qemu_vga.ndrv' 'skiboot.lid' 'slof.bin' 'pnv-pnor.bin' 'vof*.bin'
    'u-boot-sam460.bin' 'u-boot.e500'                  # ppc
    's390-ccw.img'
    'qemu-nsis.bmp'                # Windows installer artwork
)

is_macho() { file -b "$1" | grep -q '^Mach-O'; }

# Non-system libraries a Mach-O file links against, without its own install name.
linked_libs() {
    local id
    id="$(otool -D "$1" | tail -n +2)"
    otool -L "$1" | tail -n +2 | awk '{print $1}' |
        grep -vE '^(/usr/lib/|/System/)' | grep -vxF "${id:-//}" || true
}

# install_name_tool without its warning that the signature becomes invalid;
# bundle_libs re-signs every file afterwards.
change_names() {
    install_name_tool "$@" 2>&1 | { grep -v 'invalidate the code signature' >&2 || true; }
}

rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/ {f=1} f && $1 == "path" {print $2; f=0}'; }

# Homebrew keg (Cellar/<formula>/<version>) a library was installed from.
brew_keg() {
    local real
    real="$(realpath "$1")"
    [[ "$real" == */Cellar/*/*/* ]] || return 1
    echo "${real%/lib/*}"
}

stage_files() {
    log "staging $PKG"
    rm -rf "$BUILD/package"   # earlier versions, notarization leftovers
    mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share"

    local f
    for f in "$PREFIX"/bin/*; do
        # virglrenderer's test server is a development tool.
        [ "$(basename "$f")" = virgl_test_server ] && continue
        cp -p "$f" "$STAGE/bin/"
    done
    # libGLESv1_CM is not used: virglrenderer needs GLES 2+, and gl=on uses
    # OpenGL.framework directly.
    for f in libepoxy.0 libvirglrenderer.1 libEGL libGLESv2; do
        cp -p "$PREFIX/lib/$f.dylib" "$STAGE/lib/"
    done

    cp -pR "$PREFIX/share/qemu" "$STAGE/share/"
    (cd "$STAGE/share/qemu" && rm -rf "${OTHER_ARCH_FIRMWARE[@]}")
}

# Copy every non-system library the staged binaries need into lib/ and point
# all references at @rpath/<name>. Binaries search ../lib, libraries their own
# directory.
bundle_libs() {
    log "bundling libraries"
    local queue=("$STAGE"/bin/* "$STAGE"/lib/*.dylib) f lib name
    while [ ${#queue[@]} -gt 0 ]; do
        f="${queue[0]}"
        queue=("${queue[@]:1}")
        is_macho "$f" || continue
        while read -r lib; do
            [ -n "$lib" ] || continue
            name="$(basename "$lib")"
            case "$lib" in
                @rpath/*|@loader_path/*|@executable_path/*) ;;
                /*)
                    [ -f "$lib" ] || die "$(basename "$f") links $lib, which doesn't exist"
                    if [ ! -f "$STAGE/lib/$name" ]; then
                        brew_keg "$lib" >/dev/null ||
                            die "$(basename "$f") links $lib, which is neither ours nor from Homebrew"
                        cp "$(realpath "$lib")" "$STAGE/lib/$name"
                        chmod u+w "$STAGE/lib/$name"
                        queue+=("$STAGE/lib/$name")
                    fi
                    ;;
                *) die "$(basename "$f") links $lib, a relative path" ;;
            esac
            [ -f "$STAGE/lib/$name" ] || die "$(basename "$f") links $lib, which isn't in the package"
            [ "$lib" = "@rpath/$name" ] || change_names -change "$lib" "@rpath/$name" "$f"
        done < <(linked_libs "$f")
    done

    local rp want
    for f in "$STAGE"/bin/* "$STAGE"/lib/*.dylib; do
        is_macho "$f" || continue
        if [[ "$f" == *.dylib ]]; then
            change_names -id "@rpath/$(basename "$f")" "$f"
            want=@loader_path
        else
            want=@executable_path/../lib
        fi
        while read -r rp; do
            if [ -n "$rp" ] && [ "$rp" != "$want" ]; then
                change_names -delete_rpath "$rp" "$f"
            fi
        done < <(rpaths "$f")
        rpaths "$f" | grep -qxF "$want" || change_names -add_rpath "$want" "$f"
    done
}

# entitlements <file>: the entitlements it is signed with, one per line.
entitlements() {
    # Library validation only accepts libraries signed by the same team, and
    # ad hoc signatures have no team.
    if [ "$SIGN_IDENTITY" = - ] && [[ "$1" != *.dylib ]]; then
        echo com.apple.security.cs.disable-library-validation
    fi
    case "$1" in
        # HVF; TCG's JIT (MAP_JIT code buffer); audio capture for -audiodev coreaudio.
        qemu-system-aarch64)
            echo com.apple.security.hypervisor
            echo com.apple.security.cs.allow-jit
            echo com.apple.security.device.audio-input ;;
        # No HVF: x86_64 guests on Apple Silicon always run under TCG.
        qemu-system-*)
            echo com.apple.security.cs.allow-jit
            echo com.apple.security.device.audio-input ;;
    esac
}

# Sign everything with the hardened runtime, which notarization requires. Ad
# hoc packages get it too, so CI tests run under the same restrictions as a
# release (the JIT entitlement for TCG, for example). install_name_tool already
# invalidated the original signatures.
sign_files() {
    log "signing with identity: $SIGN_IDENTITY"
    local f name plist args
    for f in "$STAGE"/lib/*.dylib "$STAGE"/bin/*; do
        is_macho "$f" || continue
        name="$(basename "$f")"
        args=(--force --sign "$SIGN_IDENTITY" --options runtime)
        [ "$SIGN_IDENTITY" = - ] || args+=(--timestamp)
        if [ -n "$(entitlements "$name")" ]; then
            plist="$BUILD/package/$name.entitlements"
            {
                echo '<?xml version="1.0" encoding="UTF-8"?>'
                echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
                echo '<plist version="1.0"><dict>'
                entitlements "$name" | sed 's|.*|<key>&</key><true/>|'
                echo '</dict></plist>'
            } >"$plist"
            args+=(--entitlements "$plist")
        fi
        codesign "${args[@]}" "$f"
    done
}

# Submit the signed files to Apple's notary service. Bare Mach-O files can't
# carry a stapled ticket; Gatekeeper looks the ticket up online instead.
notarize() {
    local creds=()
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        creds=(--keychain-profile "$NOTARY_PROFILE")
    elif [ -n "${NOTARY_KEY:-}" ]; then
        creds=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
    else
        log "warning: no notary credentials (NOTARY_PROFILE or NOTARY_KEY); not notarizing"
        return 0
    fi
    local zip="$BUILD/package/$PKG-notarize.zip" result id status
    log "notarizing (this usually takes a few minutes)"
    rm -f "$zip"
    ditto -c -k --keepParent "$STAGE" "$zip"
    result="$(xcrun notarytool submit "$zip" "${creds[@]}" --wait --output-format json)"
    rm -f "$zip"
    id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$result")"
    status="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$result")"
    if [ "$status" != Accepted ]; then
        xcrun notarytool log "$id" "${creds[@]}" >&2 || true
        die "notarization $id: $status"
    fi
    log "notarization $id: $status"
    notarized=1
}

# license_files <dir>: license files at the top of a source or keg directory.
license_files() {
    find "$1" -maxdepth 1 -type f \( -iname 'licen[cs]e*' -o -iname 'copying*' \
        -o -iname 'copyright*' -o -iname '*gpl*.txt' \) | sort
}

copy_licenses() {
    local name="$1" dir="$2" dest="$STAGE/LICENSES/$1" files
    files="$(license_files "$dir")"
    [ -n "$files" ] || die "$name: no license file in $dir"
    mkdir -p "$dest"
    while read -r f; do cp "$f" "$dest/"; done <<<"$files"
}

# ANGLE statically links Chromium third-party code: collect the license of
# every third_party directory its libraries depend on, as named in each
# README.chromium.
angle_licenses() (
    local out="$BUILD/angle" dir file
    use_xcode   # gn's toolchain setup runs xcodebuild, as in build_angle
    cd "$SRC/angle" || exit 1
    for t in libGLESv2 libEGL; do
        buildtools/mac/gn desc "$out" "//:$t" deps --all
    done | grep -oE '^//([^:]*/)?third_party/[^:/]+' | sort -u | while read -r dir; do
        dir="${dir#//}"
        dir="${dir#buildtools/}"   # buildtools/third_party/libc++ builds third_party/libc++
        file=
        if [ -f "$dir/README.chromium" ]; then
            file="$(sed -n 's/^License File: *//p' "$dir/README.chromium" | head -1)"
        fi
        [ -n "$file" ] || file="$(cd "$dir" && ls src/LICENSE* LICENSE* 2>/dev/null | head -1 || true)"
        [ -n "$file" ] && [ -f "$dir/$file" ] || die "angle: no license file for $dir"
        mkdir -p "$STAGE/LICENSES/angle/$dir"
        cp "$dir/$file" "$STAGE/LICENSES/angle/$dir/"
    done
)

# Remember which Homebrew keg each library we bundle comes from, as
# "<library> <keg>" lines in $ORIGINS, before bundle_libs rewrites the links.
record_origins() {
    local f lib
    : >"$ORIGINS"
    for f in "$PREFIX"/bin/* "$PREFIX"/lib/*.dylib; do
        is_macho "$f" || continue
        linked_libs "$f"
    done | { grep '^/' || true; } | sort -u | while read -r lib; do
        origins_walk "$lib"
    done
}

origins_walk() {
    local lib="$1" keg dep
    grep -q "^$(basename "$lib") " "$ORIGINS" && return 0
    keg="$(brew_keg "$lib")" || return 0
    echo "$(basename "$lib") $keg" >>"$ORIGINS"
    while read -r dep; do
        if [[ "$dep" == /* ]]; then
            origins_walk "$dep"
        fi
    done < <(linked_libs "$lib")
}

# Bundled Homebrew formulae as "<formula> <version> <keg>" lines.
bundled_formulae() {
    local lib keg
    while read -r lib keg; do
        echo "$(basename "$(dirname "$keg")") $(basename "$keg") $keg"
    done <"$ORIGINS" | sort -u
}

write_licenses() {
    log "collecting licenses"
    copy_licenses "$PACKAGE_NAME" "$ROOT"
    copy_licenses qemu "$SRC/qemu"
    copy_licenses virglrenderer "$SRC/virglrenderer"
    copy_licenses libepoxy "$SRC/libepoxy"
    copy_licenses angle "$SRC/angle"
    angle_licenses
    local formula version keg
    while read -r formula version keg; do
        copy_licenses "$formula" "$keg"
    done < <(bundled_formulae)
}

# Lowest macOS version every Mach-O file supports.
min_macos() {
    local f
    for f in "$STAGE"/bin/* "$STAGE"/lib/*.dylib; do
        is_macho "$f" || continue
        otool -l "$f" | awk '/LC_BUILD_VERSION/ {f=1} f && $1 == "minos" {print $2; exit}'
    done | sort -V | tail -1
}

quarantine_note() {
    if [ $notarized -eq 1 ]; then
        echo "The binaries are signed with a Developer ID and notarized by Apple."
        return
    fi
    cat <<EOF
The binaries are not notarized. If macOS refuses to run them ("cannot be
verified"), the archive was downloaded with a browser and is quarantined.
Clear the flag once:

    xattr -dr com.apple.quarantine $PKG
EOF
}

write_readme() {
    local formula version keg min
    min="$(min_macos)"
    {
        cat <<EOF
# $PACKAGE_NAME $PACKAGE_VERSION

QEMU $QEMU_VERSION for Apple Silicon Macs with OpenGL acceleration for Linux
guests: \`-device virtio-gpu-gl-pci -display cocoa,gl=es\` (or \`gl=on\`).
Requires macOS $min or later.

This directory is self-contained: it doesn't need Homebrew and can be moved
anywhere. Add \`bin/\` to your PATH or run the binaries by their full path.

$(quarantine_note)

## Example

    cp share/qemu/edk2-arm-vars.fd vars.fd
    bin/qemu-img create -f qcow2 disk.qcow2 64G
    bin/qemu-system-aarch64 \\
        -M virt,accel=hvf -cpu host -smp 4 -m 8G \\
        -drive if=pflash,format=raw,readonly=on,file=share/qemu/edk2-aarch64-code.fd \\
        -drive if=pflash,format=raw,file=vars.fd \\
        -device virtio-gpu-gl-pci -display cocoa,gl=es \\
        -device qemu-xhci -device usb-kbd -device usb-tablet \\
        -nic user,model=virtio-net-pci \\
        -drive if=virtio,format=qcow2,file=disk.qcow2

## Contents

| Component | Version | License |
|---|---|---|
| QEMU | $QEMU_VERSION + patches | GPL-2.0 |
| virglrenderer | ${VIRGLRENDERER_REF#virglrenderer-} + patches | MIT |
| libepoxy | $LIBEPOXY_REF + patches | MIT |
| ANGLE | \`$ANGLE_BRANCH\` (\`${ANGLE_REF:0:12}\`), Metal backend | BSD-3-Clause |
EOF
        while read -r formula version keg; do
            echo "| $formula (from Homebrew) | $version | see \`LICENSES/$formula\` |"
        done < <(bundled_formulae)
        cat <<EOF

License texts are in \`LICENSES/\`, firmware licenses in
\`share/qemu/edk2-licenses.txt\`.

## Source

Built from $PROJECT_URL at
\`$(git -C "$ROOT" rev-parse HEAD)\`: the upstream releases above plus the
patches in that repository's \`patches/\` directory. The complete corresponding
source is published next to this archive as \`$PKG-source.tar\`.
EOF
    } >"$STAGE/README.md"
}

make_tarball() {
    log "writing $TARBALL"
    mkdir -p "$DIST"
    rm -f "$TARBALL" "$TARBALL.sha256"
    # No AppleDouble (._*) entries or extended attributes; numeric root owner.
    tar -C "$(dirname "$STAGE")" --no-mac-metadata --no-xattrs \
        --uid 0 --gid 0 --uname root --gname wheel \
        --options xz:compression-level=9,xz:threads=0 \
        -cJf "$TARBALL" "$PKG"
    (cd "$DIST" && shasum -a 256 "$(basename "$TARBALL")" >"$(basename "$TARBALL").sha256")
    log "$(du -h "$TARBALL" | cut -f1) $(basename "$TARBALL")"
}

# Corresponding source: everything needed to rebuild the binaries.
make_source() {
    local out="$DIST/$PKG-source.tar" dir="$BUILD/package/$PKG-source" dl="$BUILD/downloads"
    log "writing $out"
    rm -rf "$dir"
    mkdir -p "$dir/upstream" "$dl"

    [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] ||
        log "warning: uncommitted changes in this repository are not in the source archive"
    git -C "$ROOT" archive --format=tar.gz --prefix="$PACKAGE_NAME/" -o "$dir/$PACKAGE_NAME.tar.gz" HEAD

    # The release tarball, unlike the git tag, includes the firmware sources
    # (roms/) and the meson subprojects.
    local qemu_tar="qemu-$QEMU_VERSION.tar.xz"
    if [ ! -f "$dl/$qemu_tar" ]; then
        curl -fL --retry 3 -o "$dl/$qemu_tar.part" "https://download.qemu.org/$qemu_tar"
        mv "$dl/$qemu_tar.part" "$dl/$qemu_tar"
    fi
    cp "$dl/$qemu_tar" "$dir/upstream/"

    git -C "$SRC/virglrenderer" archive --format=tar.gz --prefix="$VIRGLRENDERER_REF/" \
        -o "$dir/upstream/$VIRGLRENDERER_REF.tar.gz" upstream
    git -C "$SRC/libepoxy" archive --format=tar.gz --prefix="libepoxy-$LIBEPOXY_REF/" \
        -o "$dir/upstream/libepoxy-$LIBEPOXY_REF.tar.gz" upstream

    # Homebrew's source tarballs for the bundled libraries, at the installed versions.
    local formula version keg stable cached
    while read -r formula version keg; do
        stable="$(brew info --json=v2 --formula "$formula" | python3 -c \
            'import json,sys; f=json.load(sys.stdin)["formulae"][0]; r=f["revision"]; print(f["versions"]["stable"] + (f"_{r}" if r else ""))')"
        [ "$stable" = "$version" ] ||
            die "$formula: installed $version but Homebrew's formula is $stable; run brew upgrade and rebuild"
        brew fetch --quiet --build-from-source --formula "$formula" >/dev/null
        cached="$(brew --cache --build-from-source --formula "$formula")"
        cp "$cached" "$dir/upstream/$(basename "${cached#*--}")"
        # The recipe the installed bottle was built with, including any patches
        # Homebrew applies. (Not `brew cat`: it switches on developer mode.)
        cp "$keg/.brew/$formula.rb" "$dir/upstream/homebrew-$formula.rb"
    done < <(bundled_formulae)

    cat >"$dir/README.md" <<EOF
# $PKG source

Corresponding source for \`$PKG-macos-arm64.tar.xz\`.

- \`$PACKAGE_NAME.tar.gz\`: the build scripts, \`versions.env\` and the patches
  (\`patches/<component>/\`) at commit \`$(git -C "$ROOT" rev-parse HEAD)\`.
  See its README.md for build instructions.
- \`upstream/\`: the unmodified upstream sources the binaries were built from,
  and for the libraries bundled from Homebrew, the formula (\`homebrew-*.rb\`)
  they were built with.
  ANGLE (BSD-3-Clause) is not included; it is fetched from
  $ANGLE_URL at \`$ANGLE_REF\` by \`scripts/fetch.sh\`.
EOF
    tar -C "$(dirname "$dir")" --no-mac-metadata --no-xattrs \
        --uid 0 --gid 0 --uname root --gname wheel -cf "$out" "$(basename "$dir")"
    (cd "$DIST" && shasum -a 256 "$(basename "$out")" >"$(basename "$out").sha256")
    log "$(du -h "$out" | cut -f1) $(basename "$out")"
}

stage_files
record_origins
bundle_libs
sign_files
write_licenses
[ "$SIGN_IDENTITY" = - ] || notarize
write_readme
make_tarball
if [ $with_source -eq 1 ]; then
    make_source
fi
