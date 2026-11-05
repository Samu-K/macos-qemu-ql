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
- `scripts/`: `fetch.sh`, `build.sh`, `test.sh`, `export-patches.sh`, `check-updates.sh`, `package.sh`, `ci.sh` (CI entry point),
  `homebrew-formula.sh` (tap formula), shared setup in `common.sh`.
- `.github/`: `ci.yml` (PRs/main), `nightly-updates.yml` (automatic version bumps), `release.yml` (manual: build,
  sign, notarize, publish a GitHub release), `homebrew-tap.yml` (formula in `Samu-K/homebrew-tap`); see `docs/ci.md`
  and `docs/packaging.md`.
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
scripts/test.sh                       # test prefix/ (opens QEMU windows briefly); scripts/test.sh boot-es for one test
scripts/check-updates.sh              # list newer upstream stable releases
scripts/check-updates.sh --apply qemu # pin the newest qemu in versions.env (+ README table)
scripts/package.sh                    # self-contained tarball in dist/ (--source: also the source archive)
scripts/test.sh --package dist/<name>-macos-arm64.tar.xz   # test a package (adds the bundle test)
scripts/ci.sh                         # what CI runs: fetch --reset, build, test, package, test-package; logs in logs/
scripts/homebrew-formula.sh <tarball> # the tap's Formula/qemu-gl.rb for a package
gh workflow run release.yml --ref main # release main as v<qemu>-<n+1> and update the tap
```

Each `src/<component>` is a shallow git checkout with branch `upstream` (the pinned ref) and
branch `macos-gl` (upstream + our patches, checked out).

### Changing a patch

1. Work in `src/<component>` on `macos-gl`: commit, `git commit --fixup` + `git rebase -i --autosquash upstream`, etc.
2. `scripts/export-patches.sh <component>`
3. `scripts/build.sh <component>` and test.
4. Commit the `patches/` diff in this repo.

### Bumping a version

1. `scripts/check-updates.sh --apply <component>` (or edit `versions.env` by hand: latest *stable* release only;
   for ANGLE the `chromium/<build>` branch of current Chrome stable). The nightly workflow does this automatically.
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

- Lint before committing: `shellcheck -x -S warning scripts/*.sh` and `actionlint`.
- Keep patches minimal: only what's required for GL on macOS. Unrelated fixes stay out.
- Dependency policy: QEMU is configured with `--without-default-features` and an explicit feature list in
  `scripts/build.sh`. The only external runtime libraries besides the GL stack are glib, pixman, libslirp and zstd.
  Features needing only macOS frameworks or QEMU-bundled code (hvf, coreaudio, vmnet, vnc, virtfs, tools, fdt=internal,
  common image formats) are fine. Adding another external library needs the user's approval.
  Check with `otool -L prefix/bin/qemu-system-aarch64`.
- Preserve upstream authorship in patches (`git am` keeps it). New patches get a commit message that explains *why*,
  in upstream style, so they could be sent upstream as-is.
- Commits in this repo: plain messages, no Claude/AI attribution or `Co-Authored-By` trailers.
- Remote: `origin` = `git@github.com:Samu-K/macos-qemu-ql.git` (public). Don't push unless asked.
- Build host: Apple Silicon, macOS 15+, **full Xcode** plus its Metal toolchain
  (`xcodebuild -downloadComponent MetalToolchain`). ANGLE's Chromium build calls `xcodebuild` and precompiles Metal
  shaders; the Command Line Tools alone are not enough. Homebrew: `meson ninja pkgconf glib pixman libslirp zstd python`.
- `build.sh` creates `build/venv` from Homebrew's python (QEMU needs >= 3.11; virglrenderer needs PyYAML).
- ANGLE is built with the `gn`/`ninja` binaries gclient puts in `src/angle` (not depot_tools' wrappers).
