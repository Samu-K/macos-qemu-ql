# macos-qemu-gl

QEMU for macOS with OpenGL acceleration for guests (`virtio-gpu-gl` + `-display cocoa,gl=on|es`), built from the
**latest stable release** of every component plus a small set of patches.

| Component | Role | Pinned in |
|---|---|---|
| QEMU | emulator; patched `ui/cocoa.m` adds GL via CGL (`gl=on`) or ANGLE/EGL (`gl=es`) | `versions.env` |
| virglrenderer | translates guest virgl commands into host GL/GLES | `versions.env` |
| libepoxy | GL/EGL dispatch used by QEMU and virglrenderer; patched to load EGL on macOS | `versions.env` |
| ANGLE | GLES/EGL on top of Metal (only the Metal backend is built) | `versions.env` (Chrome-stable branch) |

## Layout

- `versions.env`: pinned upstream URLs and refs. This is the only place versions live.
- `patches/<component>/*.patch`: our changes, as `git format-patch` series applied with `git am`.
- `scripts/`: `fetch.sh`, `build.sh`, `export-patches.sh`, shared setup in `common.sh`.
- `docs/`: user and maintainer documentation.
- Generated and gitignored: `src/` (upstream checkouts), `build/` (build trees), `prefix/` (install), `dist/` (packages).
- `example-case/`: imported reference only (gitignored, will be deleted). Never reference it from scripts or docs.

## Workflow commands

```sh
scripts/fetch.sh                      # clone pinned sources into src/ and apply patches (all components)
scripts/fetch.sh qemu                 # ...just one component
scripts/fetch.sh --reset qemu         # discard local work in src/qemu, re-apply patches/qemu from scratch
scripts/build.sh                      # build + install everything into prefix/ (angle → libepoxy → virglrenderer → qemu)
scripts/build.sh qemu                 # rebuild one component (incremental)
rm -rf build/qemu && scripts/build.sh qemu   # clean rebuild of one component
scripts/export-patches.sh qemu        # write src/qemu commits (upstream..macos-gl) back to patches/qemu/
```

Each `src/<component>` is a shallow git checkout with branch `upstream` (the pinned ref) and
branch `macos-gl` (upstream + our patches, checked out).

### Changing a patch

1. Work in `src/<component>` on `macos-gl`: commit, `git commit --fixup` + `git rebase -i --autosquash upstream`, etc.
2. `scripts/export-patches.sh <component>`
3. `scripts/build.sh <component>` and test.
4. Commit the `patches/` diff in this repo.

### Bumping a version

1. Edit the ref in `versions.env` (latest *stable* release only. For ANGLE use the `chromium/<build>` branch
   of current Chrome stable; see https://chromiumdash.appspot.com/releases?platform=Mac).
2. `scripts/fetch.sh <component>` re-fetches and re-applies patches. If `git am` fails, resolve in
   `src/<component>` (`git am --continue`), then `scripts/export-patches.sh <component>`.
3. Drop patches that upstream has merged.
4. Rebuild and test, then commit `versions.env` and `patches/` together.

### Running

```sh
prefix/bin/qemu-system-aarch64 -M virt,accel=hvf -cpu host -m 4G \
    -device virtio-gpu-gl-pci -display cocoa,gl=es ...
```

## Conventions

- Keep patches minimal: only what's required for GL on macOS. Unrelated fixes stay out.
- Preserve upstream authorship in patches (`git am` keeps it). New patches get a commit message that explains *why*,
  in upstream style, so they could be sent upstream as-is.
- Commits in this repo: plain messages, no Claude/AI attribution or `Co-Authored-By` trailers.
- No remote yet; don't push or create GitHub repos unless asked.
- Build host: Apple Silicon, macOS 15+, **full Xcode** plus its Metal toolchain
  (`xcodebuild -downloadComponent MetalToolchain`). ANGLE's Chromium build calls `xcodebuild` and precompiles Metal
  shaders; the Command Line Tools alone are not enough. Homebrew: `meson ninja pkgconf glib pixman python`.
- `build.sh` creates `build/venv` from Homebrew's python (QEMU needs >= 3.11; virglrenderer needs PyYAML).
- ANGLE is built with the `gn`/`ninja` binaries gclient puts in `src/angle` (not depot_tools' wrappers).
