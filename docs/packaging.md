# Packaging and releases

`scripts/package.sh` turns the build in `prefix/` into a binary package that runs on any Apple Silicon Mac with a
recent enough macOS, from any directory, without Homebrew.

```sh
scripts/package.sh                 # dist/macos-qemu-gl-<version>-macos-arm64.tar.xz (+ .sha256)
scripts/package.sh --source        # ...and dist/macos-qemu-gl-<version>-source.tar (+ .sha256)
scripts/test.sh --package dist/macos-qemu-gl-<version>-macos-arm64.tar.xz
```

`<version>` is `PACKAGE_VERSION`. It defaults to `<qemu version>-g<commit>`, with `-dirty` added when this repository
has uncommitted changes. Releases set it from the tag.

## What's in the package

```
macos-qemu-gl-<version>/
  README.md        usage, component versions, source pointer
  bin/             qemu-system-aarch64, qemu-system-x86_64, qemu-img, qemu-io, qemu-nbd, ...
  lib/             libepoxy, libvirglrenderer, ANGLE's libEGL/libGLESv2,
                   glib, pixman, libslirp, zstd and their dependencies (libintl, pcre2)
  share/qemu/      firmware, keymaps
  LICENSES/        one directory per component; ANGLE's statically linked
                   third-party code under LICENSES/angle/third_party/
```

How `package.sh` builds it:

1. **Stage.** Copies `prefix/`, minus build-only files: headers, pkg-config files, `virgl_test_server`,
   `libGLESv1_CM`, and firmware for architectures we don't build (`OTHER_ARCH_FIRMWARE`). QEMU installs that firmware
   regardless of `--target-list`. If `QEMU_TARGETS` changes, revisit this list.
2. **Bundle.** Follows every non-system library link from the binaries and copies the Homebrew libraries into `lib/`.
   Every reference is rewritten to `@rpath/<name>`. Binaries get the rpath `@executable_path/../lib` and libraries get
   `@loader_path`. The link targets must be our own libraries or Homebrew kegs; anything else is an error.
3. **Re-sign.** `install_name_tool` invalidates code signatures, so every Mach-O file is signed again ad hoc. The
   existing entitlements are kept, including the `com.apple.security.hypervisor` entitlement HVF needs.
4. **Licenses.** Collected from the component sources and the Homebrew kegs. For ANGLE, `gn desc` lists the
   `third_party` code `libEGL`/`libGLESv2` link, and each `README.chromium` names the license file.
5. **Archive.** Writes an xz tarball with no AppleDouble files or extended attributes.

Runtime lookups are already relative, so nothing else needs rewriting:
- QEMU finds `share/qemu` relative to its executable.
- libepoxy loads ANGLE with `@rpath/libEGL.dylib`, which its `@loader_path` rpath resolves (patch
  `libepoxy/0002`).
- ANGLE's libEGL loads libGLESv2 from its own directory.

The minimum macOS version is whatever the build host and Homebrew's bottles target. Today that's macOS 15, the
`minos` of the Homebrew libraries. `README.md` in the package reports the highest `minos` of all bundled files.

## Testing a package

`scripts/test.sh --package <tarball>` unpacks the tarball into a temporary directory and runs the normal tests
against it. It adds the `bundle` test, which checks:

- every non-system library link is `@rpath/<name>` and the library is in the package, and there are no other rpaths;
- every code signature verifies, and `qemu-system-aarch64` still has the hypervisor entitlement;
- QEMU's firmware search path (`-L help`) is inside the package;
- in the `gl=es` boot, nothing is loaded from Homebrew or this repository's build tree (`vmmap`), and ANGLE comes from
  the package.

`scripts/ci.sh` runs `package` and `test-package` as its last two stages. CI uploads the tarball as the `package`
artifact.

## Source archive and licensing

The binaries contain GPL-2.0 code (QEMU) and LGPL code (glib, libintl). Distributing them therefore requires
offering the corresponding source. `--source` writes that archive. It contains:

- this repository at the packaged commit: build scripts, `versions.env` and patches;
- QEMU's release tarball, which unlike the git tag includes the firmware sources in `roms/` and the meson
  subprojects;
- virglrenderer and libepoxy at their pinned tags;
- for each bundled Homebrew library, its source tarball and the formula its bottle was built with
  (`<keg>/.brew/<formula>.rb`, which records any patches Homebrew applies).

ANGLE is BSD-licensed, so it's left out; `scripts/fetch.sh` fetches it from the pinned commit. Homebrew's
installed versions must match its current formulae, otherwise `--source` fails. This holds on CI's fresh runners.
Locally, run `brew upgrade` and rebuild first.

Publish the source archive next to every binary release. The release workflow does this.

## Releasing

Tags are `v<qemu version>-<n>`, for example `v11.1.3-1`. `<n>` starts at 1 for each QEMU version and goes up for
releases that change only other components or patches.

```sh
git tag v11.1.3-1
git push origin v11.1.3-1
```

The tag triggers `.github/workflows/release.yml`:
1. It checks that the tag matches the QEMU version in `versions.env`.
2. It runs `scripts/ci.sh` with the source archive enabled.
3. It creates a **draft** release with the tarball, the source archive and their checksums, plus generated notes
   listing component versions and install commands.

Review the draft on GitHub and publish it.

## Not done yet

- **Developer ID signing and notarization.** The binaries are only signed ad hoc. That's enough when the archive is
  downloaded with `curl` or Homebrew. A browser download is quarantined, and macOS refuses to run its binaries until
  the user runs `xattr -dr com.apple.quarantine <dir>`; the package README explains this. Proper signing needs a paid
  Apple Developer account and signing secrets in CI.
- **Homebrew tap.** The plan is a separate `homebrew-<name>` repository whose formula installs the release tarball.
  The tarball is self-contained, so the formula needs no dependencies, only `conflicts_with "qemu"`.
- **Intel Macs.** The package is arm64 only.
