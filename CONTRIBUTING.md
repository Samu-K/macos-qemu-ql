# Contributing

Thanks for helping. This repository builds the latest stable QEMU with OpenGL acceleration for guests on macOS
(`virtio-gpu-gl` with `-display cocoa,gl=on|es`). It is the upstream releases of QEMU, virglrenderer, libepoxy and
ANGLE plus a small set of patches. See the [README](README.md) for what it does and how to use it.

## Layout

- `versions.env`: pinned upstream URLs and refs. This is the only place versions live.
- `patches/<component>/*.patch`: our changes, as `git format-patch` series applied with `git am`.
- `scripts/`: `fetch.sh`, `build.sh`, `test.sh`, `export-patches.sh`, `check-updates.sh`, `package.sh`,
  `ci.sh` (CI entry point), `homebrew-formula.sh` (tap formula), shared setup in `common.sh`.
- `.github/`: `ci.yml` (PRs and main), `nightly-updates.yml` (automatic version bumps), `release.yml` (manual: build,
  sign, notarize, publish a GitHub release), `homebrew-tap.yml` (formula in `Samu-K/homebrew-tap`).
- `docs/`: [`ci.md`](docs/ci.md) (workflows, nightly updates, tests) and [`packaging.md`](docs/packaging.md)
  (packages, signing, releases, the tap).
- Generated and gitignored: `src/` (upstream checkouts), `build/` (build trees), `prefix/` (install), `dist/`
  (packages), `logs/`.

## Build host

Apple Silicon, macOS 15+, and **full Xcode** with its Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`). ANGLE's Chromium build calls `xcodebuild` and precompiles Metal
shaders; the Command Line Tools alone are not enough. Allow about 30 GB of disk. Homebrew packages:

```sh
brew install meson ninja pkgconf glib pixman libslirp zstd python
```

`build.sh` creates `build/venv` from Homebrew's python (QEMU needs 3.11 or newer; virglrenderer needs PyYAML).
ANGLE is built with the `gn` and `ninja` binaries gclient puts in `src/angle`, not depot_tools' wrappers.

## Workflow

```sh
scripts/fetch.sh                      # clone pinned sources into src/ and apply patches (all components)
scripts/fetch.sh qemu                 # ...just one component
scripts/fetch.sh --reset qemu         # discard local work in src/qemu, re-apply patches/qemu from scratch
scripts/build.sh                      # build and install everything into prefix/ (angle, libepoxy, virglrenderer, qemu)
scripts/build.sh qemu                 # rebuild one component (incremental)
rm -rf build/qemu && scripts/build.sh qemu   # clean rebuild of one component
scripts/export-patches.sh qemu        # write src/qemu commits (upstream..macos-gl) back to patches/qemu/
scripts/test.sh                       # test prefix/ (opens QEMU windows briefly); scripts/test.sh boot-es for one test
scripts/check-updates.sh              # list newer upstream stable releases
scripts/package.sh                    # self-contained tarball in dist/ (--source: also the source archive)
scripts/test.sh --package dist/<name>-macos-arm64.tar.xz   # test a package (adds the bundle test)
scripts/ci.sh                         # what CI runs: fetch --reset, build, test, package, test-package; logs in logs/
```

Each `src/<component>` is a shallow git checkout with branch `upstream` (the pinned ref) and branch `macos-gl`
(upstream plus our patches, checked out).

### Changing a patch

1. Work in `src/<component>` on `macos-gl`: commit, or `git commit --fixup` and
   `git rebase -i --autosquash upstream`.
2. `scripts/export-patches.sh <component>`
3. `scripts/build.sh <component>` and `scripts/test.sh`.
4. Commit the `patches/` diff in this repository.

Patch rules:

- Keep patches minimal: only what is required for GL on macOS. Unrelated fixes stay out.
- Preserve upstream authorship (`git am` keeps it).
- Write the commit message of a new patch in the upstream project's style and explain *why*, so it could be sent
  upstream as-is.

### Bumping a version

The [nightly workflow](docs/ci.md#nightly-updates) does this automatically: it opens a PR per new upstream release and
merges it when CI passes. Don't bump versions by hand unless that PR fails. Then:

1. `git switch update/<component>-<version>`.
2. `scripts/fetch.sh <component>` re-fetches and re-applies patches. If `git am` fails, resolve it in
   `src/<component>` (`git am --continue`), then `scripts/export-patches.sh <component>`.
3. Drop patches that upstream has merged.
4. Rebuild and test, then commit `versions.env` and `patches/` together and push to the branch.

Only the latest *stable* release counts (for ANGLE, the `chromium/<build>` branch of current Chrome stable).
`scripts/check-updates.sh --apply <component>` pins the newest one in `versions.env` and the README table.

## Dependency policy

QEMU is configured with `--without-default-features` and an explicit feature list in `scripts/build.sh`. The only
external runtime libraries besides the GL stack are glib, pixman, libslirp and zstd. Features that need only macOS
frameworks or QEMU-bundled code (hvf, coreaudio, vmnet, vnc, virtfs, tools, fdt=internal, common image formats) are
fine. Adding another external library needs maintainer approval; open an issue first. Check with:

```sh
otool -L prefix/bin/qemu-system-aarch64
```

## Before you open a pull request

- Lint: `shellcheck -x -S warning scripts/*.sh` and `actionlint`.
- Run `scripts/test.sh`. CI (`ci.yml`) runs the full `scripts/ci.sh` on every pull request.
- Commit messages are plain: a short summary line, and a body that explains why when it isn't obvious.
- Keep changes focused, and update the docs and README when behavior changes.

## Releases

Releases are cut by the maintainer with the manual `release.yml` workflow, which builds, signs, notarizes and
publishes a GitHub release and updates the Homebrew tap. See [`docs/packaging.md`](docs/packaging.md#releasing).
