#!/usr/bin/env bash
# Build the components in src/ and install them into $PREFIX (default: prefix/).
#
#   scripts/build.sh [component...]
#
# Components build in dependency order: angle libepoxy virglrenderer qemu.
# Re-running is incremental; delete build/<component> for a clean rebuild.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

build_angle() {
    local out="$BUILD/angle"
    # Metal backend only: gl=es renders through ANGLE-on-Metal, while gl=on
    # uses Apple's OpenGL.framework directly and never touches ANGLE.
    local args=(
        is_debug=false
        symbol_level=0
        "install_prefix=\"$PREFIX\""
        angle_enable_metal=true
        angle_enable_vulkan=false
        angle_enable_gl=false
        angle_enable_null=false
        angle_enable_wgpu=false
        angle_has_frame_capture=false
        angle_build_tests=false
    )
    (cd "$SRC/angle" && gn gen "$out" --args="${args[*]}")
    ninja -C "$out" install_angle
}

# meson_build <component> [meson setup options...]
meson_build() {
    local c="$1" out="$BUILD/$1"
    shift
    if [ ! -f "$out/build.ninja" ]; then
        meson setup "$out" "$SRC/$c" --prefix="$PREFIX" --libdir=lib \
            --buildtype=release "$@"
    fi
    meson compile -C "$out"
    meson install -C "$out" --quiet
}

build_libepoxy() {
    meson_build libepoxy -Degl=yes -Dglx=no -Dx11=false -Dtests=false
}

build_virglrenderer() {
    meson_build virglrenderer -Dtests=false
}

build_qemu() {
    local out="$BUILD/qemu"
    mkdir -p "$out"
    if [ ! -f "$out/build.ninja" ]; then
        (cd "$out" && "$SRC/qemu/configure" \
            --prefix="$PREFIX" \
            --target-list="$QEMU_TARGETS" \
            --enable-cocoa \
            --enable-opengl \
            --enable-virglrenderer \
            --enable-hvf \
            --disable-sdl \
            --disable-gtk \
            --disable-docs \
            --disable-werror)
    fi
    make -C "$out" -j"$JOBS"
    make -C "$out" install
}

read -r -a selected <<<"$(select_components "$@")"

for c in "${selected[@]}"; do
    [ -d "$SRC/$c/.git" ] || die "$c: src/$c missing; run scripts/fetch.sh $c first"
    log "$c: building"
    "build_${c}"
done

log "installed into $PREFIX"
