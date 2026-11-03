#!/usr/bin/env bash
# Build the components in src/ and install them into $PREFIX (default: prefix/).
#
#   scripts/build.sh [component...]
#
# Components build in dependency order: angle libepoxy virglrenderer qemu.
# Re-running is incremental; delete build/<component> for a clean rebuild.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Subshell so DEVELOPER_DIR from use_xcode doesn't leak into other components.
build_angle() (
    local out="$BUILD/angle"
    use_xcode
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
    # Use the gn/ninja binaries gclient pinned in the ANGLE tree; depot_tools'
    # gn wrapper would first need its own Python bootstrap.
    (cd "$SRC/angle" && buildtools/mac/gn gen "$out" --args="${args[*]}")
    "$SRC/angle/third_party/ninja/ninja" -C "$out" install_angle

    # Chromium links these with a cwd-relative "./libEGL.dylib" install name.
    local lib
    for lib in libEGL libGLESv1_CM libGLESv2; do
        install_name_tool -id "@rpath/$lib.dylib" "$PREFIX/lib/$lib.dylib"
    done
)

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
    # Require EGL so a libepoxy without EGL support fails here, not at runtime.
    meson_build virglrenderer -Dplatforms=egl -Dtests=false
}

build_qemu() {
    local out="$BUILD/qemu"
    mkdir -p "$out"
    if [ ! -f "$out/build.ninja" ]; then
        # Explicit feature list instead of auto-detection, so the result
        # doesn't depend on what happens to be installed on the build host.
        # External libraries: the GL stack plus glib, pixman, libslirp, zstd.
        # The rest only needs macOS frameworks or code bundled with QEMU.
        (cd "$out" && "$SRC/qemu/configure" \
            --prefix="$PREFIX" \
            --target-list="$QEMU_TARGETS" \
            --without-default-features \
            --disable-werror \
            --enable-cocoa \
            --enable-opengl \
            --enable-virglrenderer \
            --enable-hvf \
            --enable-pixman \
            --enable-slirp \
            --enable-zstd \
            --enable-coreaudio \
            --enable-vmnet \
            --enable-vnc \
            --enable-virtfs \
            --enable-tools \
            --enable-fdt=internal \
            --enable-vdi \
            --enable-vhdx \
            --enable-vmdk \
            --enable-vpc)
    fi
    make -C "$out" -j"$JOBS"
    make -C "$out" install
}

# Python for the meson-based builds: QEMU's configure needs >= 3.11 (the
# macOS system python is 3.9) and virglrenderer's codegen needs PyYAML.
setup_venv() {
    local venv="$BUILD/venv" py
    py="$(brew --prefix)/bin/python3"
    if [ ! -x "$venv/bin/python3" ]; then
        log "creating build venv"
        "$py" -m venv "$venv"
        "$venv/bin/pip" install --quiet --disable-pip-version-check pyyaml
    fi
    export PATH="$venv/bin:$PATH"
}

read -r -a selected <<<"$(select_components "$@")"

setup_venv
for c in "${selected[@]}"; do
    [ -d "$SRC/$c/.git" ] || die "$c: src/$c missing; run scripts/fetch.sh $c first"
    log "$c: building"
    "build_${c}"
done

log "installed into $PREFIX"
