# macos-qemu-gl

Builds the latest stable QEMU for Apple Silicon with `virtio-gpu-gl` (virgl) support, so Linux guests get OpenGL rendered on the host GPU through Metal.

## Why

Official QEMU builds, including Homebrew's, have no OpenGL in the Cocoa display, and macOS lacks the EGL and OpenGL ES that virgl needs. Guests fall back to a software framebuffer.

The patches exist, mostly Akihiko Odaki's macOS virgl work, but aren't upstream yet. This repo applies them to the latest stable release of every component.

## How it works

```
 Linux guest (Mesa virgl driver)
        │ OpenGL commands over virtio-gpu
        ▼
 QEMU ──► virglrenderer ──► libepoxy ──┬─► gl=es: ANGLE (OpenGL ES) ──► Metal ──► GPU
                                       └─► gl=on: Apple OpenGL.framework ───────► GPU
        │
        ▼
 QEMU Cocoa window
```

| Display mode | Host API | Notes |
|---|---|---|
| `-display cocoa,gl=es` | OpenGL ES 3.0 via [ANGLE](https://chromium.googlesource.com/angle/angle) on Metal | Recommended. Uses the maintained Metal driver. |
| `-display cocoa,gl=on` | OpenGL 4.1 Core via Apple's `OpenGL.framework` | No extra libraries, but Apple's OpenGL is deprecated and frozen at 4.1. |

### What's built

<!-- versions:start -->
| Component | Version |
|---|---|
| [QEMU](https://www.qemu.org) | 11.1.3 (`qemu-system-aarch64`, `qemu-system-x86_64`, `qemu-img`) |
| [virglrenderer](https://gitlab.freedesktop.org/virgl/virglrenderer) | 1.3.0 |
| [libepoxy](https://github.com/anholt/libepoxy) | 1.5.10 |
| [ANGLE](https://chromium.googlesource.com/angle/angle) | Chrome 156 stable branch (`chromium/8078`), Metal backend only |
<!-- versions:end -->

Each component is the upstream release plus the patches in [`patches/`](patches/); exact refs are in [`versions.env`](versions.env). The only other runtime libraries are Homebrew's glib, pixman, libslirp and zstd.

## Status

The stack builds, and QEMU boots UEFI firmware with HVF under both `gl=es` and `gl=on`. Accelerated rendering inside a Linux guest hasn't been verified yet. Releases are signed and notarized binaries, also installable with Homebrew; the first one is still to come.

## Installing

With Homebrew:

```sh
brew unlink qemu              # only if Homebrew's qemu is installed; the two conflict
brew install samu-k/tap/qemu-gl
```

Firmware is in `$(brew --prefix qemu-gl)/libexec/share/qemu`. Without Homebrew, download `macos-qemu-gl-<version>-macos-arm64.tar.xz` from [Releases](https://github.com/Samu-K/macos-qemu-ql/releases) and unpack it anywhere; it is self-contained.

The examples below use a build from source, in `prefix/`.

## Building

Requirements: Apple Silicon, macOS 15+, Homebrew, about 30 GB of disk, and full Xcode with its Metal toolchain (the Command Line Tools alone can't build ANGLE).

One-time Xcode setup:

```sh
X=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
sudo $X -license accept
sudo $X -runFirstLaunch
$X -downloadComponent MetalToolchain
```

Build:

```sh
brew install meson ninja pkgconf glib pixman libslirp zstd python
scripts/fetch.sh    # download pinned sources and apply patches (large ANGLE download)
scripts/build.sh    # build and install into prefix/
```

Binaries end up in `prefix/bin`, firmware in `prefix/share/qemu`.

To make a self-contained tarball that runs anywhere without Homebrew, run `scripts/package.sh`. See [`docs/packaging.md`](docs/packaging.md).

## Usage

Acceleration needs `-device virtio-gpu-gl-pci` and `-display cocoa,gl=es`. Example: installing an aarch64 Linux distribution from an ISO:

```sh
cp prefix/share/qemu/edk2-arm-vars.fd vars.fd        # writable UEFI variable store, once per VM
prefix/bin/qemu-img create -f qcow2 disk.qcow2 64G   # once per VM

prefix/bin/qemu-system-aarch64 \
    -M virt,accel=hvf -cpu host -smp 4 -m 8G \
    -drive if=pflash,format=raw,readonly=on,file=prefix/share/qemu/edk2-aarch64-code.fd \
    -drive if=pflash,format=raw,file=vars.fd \
    -device virtio-gpu-gl-pci -display cocoa,gl=es \
    -device qemu-xhci -device usb-kbd -device usb-tablet \
    -nic user,model=virtio-net-pci \
    -drive if=virtio,format=qcow2,file=disk.qcow2 \
    -device virtio-scsi-pci -device scsi-cd,drive=cd \
    -drive if=none,id=cd,media=cdrom,readonly=on,file=installer.iso
```

After installation, drop the last two lines. Inside the guest, check with:

```sh
glxinfo -B | grep renderer      # expect: OpenGL renderer string: virgl (...)
```

Notes:
- The guest needs Mesa's `virgl` driver, which mainstream Linux distributions ship. Windows and macOS guests have none.
- `qemu-system-x86_64` uses TCG on Apple Silicon, so it's slow; the GPU path is the same.
- Only OpenGL and OpenGL ES are accelerated, not Vulkan.
- `-nic vmnet-shared` requires running QEMU as root.

## Development

[`CLAUDE.md`](CLAUDE.md) describes the maintainer workflow (changing patches, bumping versions). A nightly GitHub Actions job builds and tests new upstream releases; see [`docs/ci.md`](docs/ci.md).

Packaging, releases and the Homebrew tap are described in [`docs/packaging.md`](docs/packaging.md).

## Credits

The macOS GL support in QEMU, virglrenderer, libepoxy and ANGLE is largely the work of **Akihiko Odaki**.

## License

This repository's own files (scripts, workflows, docs) are under the [MIT License](LICENSE).

The patches in [`patches/`](patches/) modify upstream code and are under the license of the project they apply to, as are the built binaries: QEMU GPL-2.0, virglrenderer and libepoxy MIT, ANGLE BSD-3-Clause. A binary distribution of QEMU must therefore follow GPL-2.0, including offering the corresponding source (the pinned upstream refs plus these patches).
