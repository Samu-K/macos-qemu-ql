# macos-qemu-gl

**QEMU for macOS with hardware-accelerated 3D graphics for guests.**

This repository builds the latest stable QEMU with `virtio-gpu-gl` (virgl) support on Apple Silicon. Linux guests get a GPU-accelerated OpenGL driver whose rendering runs on your Mac's GPU through Metal.

## Why this exists

On Linux, QEMU can give a guest an accelerated GPU: `-device virtio-gpu-gl -display gtk,gl=on`. The guest's Mesa `virgl` driver sends OpenGL commands to the host, which renders them on the real GPU.

QEMU on macOS can't do this. Official builds, including Homebrew's `qemu`, have no OpenGL support in the Cocoa display, and macOS lacks the pieces virgl needs (EGL and OpenGL ES). Guests fall back to a software-rendered framebuffer, so desktops, browsers and anything 3D are slow.

The required patches exist, mostly Akihiko Odaki's long-running macOS virgl work, but they aren't upstream yet. The community builds that carry them tend to lag far behind current releases. This repo applies them to the **latest stable release of every component** and keeps them there.

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
| `-display cocoa,gl=es` | OpenGL ES 3.0 via [ANGLE](https://chromium.googlesource.com/angle/angle) on Metal | **Recommended.** Uses the actively maintained Metal driver. |
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

Each component is the upstream release plus the patches in [`patches/`](patches/). Exact refs are in [`versions.env`](versions.env).

The only runtime libraries outside this stack are glib, pixman, libslirp and zstd from Homebrew.

## Status

Early, but working:
- **Done:** the full stack builds, and QEMU boots UEFI firmware with HVF under both `gl=es` and `gl=on`.
- **Not done yet:** accelerated rendering inside a Linux guest hasn't been verified.
- **Planned:** prebuilt binaries and a Homebrew tap. Until those exist, build from source.

## Building

Requirements:
- **Mac:** Apple Silicon running macOS 15 or later.
- **Xcode:** the full app with its Metal toolchain. The Command Line Tools alone are not enough, because building ANGLE needs both.
- **Homebrew.**
- **Disk:** about 30 GB free, mostly for ANGLE's Chromium build dependencies.

One-time Xcode setup. The full path works even when `xcode-select` points at the Command Line Tools.

```sh
X=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
sudo $X -license accept
sudo $X -runFirstLaunch
$X -downloadComponent MetalToolchain
```

Build:

```sh
brew install meson ninja pkgconf glib pixman libslirp zstd python
scripts/fetch.sh    # download pinned sources and apply patches  (first run: large ANGLE download)
scripts/build.sh    # build everything and install into prefix/
```

The result is in `prefix/`. Binaries are in `prefix/bin`, and firmware is in `prefix/share/qemu`.

## Usage

The parts that enable acceleration are `-device virtio-gpu-gl-pci` and `-display cocoa,gl=es`. A complete example that installs an aarch64 Linux distribution from an ISO:

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

After installation, drop the last two lines. To check that acceleration works, run this inside the guest:

```sh
glxinfo -B | grep renderer      # expect: OpenGL renderer string: virgl (...)
```

Things to know:
- **Guests.** The guest needs Mesa's `virgl` driver, which every mainstream Linux distribution ships. Windows and macOS guests have no virgl driver.
- **x86_64 guests.** `qemu-system-x86_64` uses software CPU emulation (TCG) on Apple Silicon, so it's slow, although the GPU path is the same.
- **Vulkan.** Not supported; only OpenGL and OpenGL ES are accelerated.
- **Bridged networking.** `-nic vmnet-shared` (vmnet) requires running QEMU as root.

## Development

[`CLAUDE.md`](CLAUDE.md) has the maintainer workflow: changing a patch, re-exporting patch files, and bumping a version.

A nightly GitHub Actions job checks for new upstream releases, then builds and tests them. Passing updates are merged automatically; failing ones get a pull request and an issue. See [`docs/ci.md`](docs/ci.md).

## Credits

The macOS GL support in QEMU, virglrenderer, libepoxy and ANGLE is largely the work of **Akihiko Odaki**.

## License

This repository's own files (scripts, workflows, docs) are under the [MIT License](LICENSE).

The patches in [`patches/`](patches/) modify upstream code and are under the license of the project they apply to, as are the built binaries: QEMU GPL-2.0, virglrenderer and libepoxy MIT, ANGLE BSD-3-Clause. A binary distribution of QEMU must therefore follow GPL-2.0, including offering the corresponding source (the pinned upstream refs plus these patches).
