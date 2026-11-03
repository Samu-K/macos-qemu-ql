# macos-qemu-gl

QEMU for macOS with **3D acceleration for guests**: `virtio-gpu-gl` with `-display cocoa,gl=on` or `gl=es`, running natively on Apple Silicon with HVF.

Upstream QEMU on macOS has no OpenGL display backend, so `virtio-gpu-gl` and `gl=on` aren't available there (they are on Linux). This project builds the **latest stable** QEMU and its GL stack with the few patches needed to close that gap.

> Status: work in progress. Builds from source; prebuilt binaries and a Homebrew tap are planned.

## How it works

```
 guest (Linux, Mesa virgl driver)
        │  virgl command stream over virtio-gpu
        ▼
 QEMU virtio-gpu-gl ──► virglrenderer ──► libepoxy ──┬─► gl=on : OpenGL.framework (CGL, GL 4.1 Core)
                                                     └─► gl=es : ANGLE (EGL + GLES 3) ──► Metal
        ▼
 QEMU ui/cocoa: blits the guest scanout into a CAOpenGLLayer (gl=on)
                or into a CAMetalLayer drawable via EGLImage (gl=es)
```

- **`gl=es` (recommended)**: GLES 3.0 through [ANGLE](https://chromium.googlesource.com/angle/angle)'s Metal backend. This is the actively maintained path on Apple GPUs.
- **`gl=on`**: desktop OpenGL 4.1 Core through Apple's deprecated `OpenGL.framework`. No extra libraries, but Apple's GL is frozen at 4.1.

## Components and patches

| Component | Version | Patches |
|---|---|---|
| QEMU | 11.1.3 | `ui/cocoa`: GL support via CGL and ANGLE/EGL (Akihiko Odaki's series, v23); EGL build fix for macOS |
| virglrenderer | 1.3.0 | GLES 3.0 blitter shaders; integer vertex attributes on ANGLE/Apple |
| libepoxy | 1.5.10 | EGL on macOS (backport of an upstream change merged after 1.5.10); find EGL next to libepoxy via `@rpath`; resolve EGL 1.5 client functions before a display exists |
| ANGLE | Chrome 156 stable (`chromium/8078`) | none |

Exact refs live in [`versions.env`](versions.env) and patches in [`patches/`](patches/). Most of the patch work is by **Akihiko Odaki**, who wrote the original macOS virgl/ANGLE integration.

## Building

Requirements: Apple Silicon Mac, macOS 15+, **Xcode** (not just the Command Line Tools) with the Metal toolchain, Homebrew, and about 30 GB of free disk (most of it for ANGLE's Chromium build dependencies).

One-time Xcode setup. The full paths work even if `xcode-select` still points at the Command Line Tools; `build.sh` uses Xcode only for the ANGLE step.

```sh
X=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
sudo $X -license accept
sudo $X -runFirstLaunch                 # installs frameworks the next step needs
$X -downloadComponent MetalToolchain    # ~700 MB; Xcode 26+ ships it separately
```

Then:

```sh
brew install meson ninja pkgconf glib pixman python
scripts/fetch.sh    # clone pinned sources into src/, apply patches
scripts/build.sh    # build and install into prefix/
```

## Running

```sh
prefix/bin/qemu-system-aarch64 \
    -M virt,accel=hvf -cpu host -smp 4 -m 4G \
    -device virtio-gpu-gl-pci \
    -display cocoa,gl=es \
    -device qemu-xhci -device usb-kbd -device usb-tablet \
    -drive if=pflash,format=raw,readonly=on,file=prefix/share/qemu/edk2-aarch64-code.fd \
    -drive if=virtio,format=qcow2,file=disk.qcow2
```

The guest needs Mesa's virgl driver, which every mainstream Linux distribution ships. Check inside the guest with `glxinfo -B` or `eglinfo -B`; the renderer should read `virgl`.

## License

License for this repository's own scripts: not yet chosen. The patches and built binaries are under the licenses of their upstream projects (QEMU: GPL-2.0; virglrenderer, libepoxy: MIT; ANGLE: BSD-3-Clause).
