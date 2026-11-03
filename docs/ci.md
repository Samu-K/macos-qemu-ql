# CI and automated updates

Two GitHub Actions workflows, both on GitHub's Apple Silicon runners (`macos-15`):

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | pull requests, pushes to `main`, manual | `scripts/ci.sh`: fetch, build, test |
| `nightly-updates.yml` | daily 02:23 UTC, manual | finds new upstream releases, then tests, merges or reports them |

## Nightly updates

1. `scripts/check-updates.sh --json` compares `versions.env` with the latest stable releases:
   - **QEMU, virglrenderer, libepoxy:** the newest release tag, excluding release candidates.
   - **ANGLE:** the head of the `chromium/<build>` branch used by the current Chrome stable for Mac.
2. Each update runs as its own job, one at a time. The job pins the new version on branch `update/<component>-<version>`, then runs `scripts/ci.sh`.
3. It always opens a pull request. Older open update PRs for the same component are closed as superseded.
   - **Tests pass:** the PR is squash-merged right away.
   - **Tests fail:** the PR stays open, and an issue labelled `dependency-update` names the failing stage (`fetch`, `build` or `test`). The issue includes the end of that stage's log. Full logs are attached to the run as artifacts.
4. On later nights, a version whose `update/...` branch still exists is skipped, so a failure is reported once, not every night.

### Fixing a failed update

- **`fetch` failed:** a patch no longer applies. Locally:
  1. `git switch update/<component>-<version>`
  2. `scripts/fetch.sh <component>` and resolve the `git am` conflict in `src/<component>`.
  3. `scripts/export-patches.sh <component>` and commit the `patches/` change.
- **`build` or `test` failed:** fix it locally on the same branch.

Push to the branch. `ci.yml` runs on the pull request; merge it once green, then close the issue. Delete the branch if you abandon the update; the next night will retry the newest version.

## Tests (`scripts/test.sh`)

- **version:** QEMU reports the pinned version.
- **linkage:** the binaries link only what the dependency policy allows: our GL stack plus Homebrew's glib, pixman, libslirp and zstd.
- **features:** `virtio-gpu-gl-pci`, the Cocoa display with `gl=on|core|es`, and HVF are built in.
- **qemu-img:** creates qcow2, raw, VMDK, VHDX, VPC and VDI images.
- **boot-es, boot-on:** boots the bundled UEFI firmware with `virtio-gpu-gl-pci` and `-display cocoa,gl=es` / `gl=on`.
  - Passes when the firmware shell is reached, QMP reports the GL mode, and QEMU exits cleanly with nothing on stderr.
  - For `gl=es`, it also checks that ANGLE was loaded from the build.
  - This exercises EGL/CGL initialization and virglrenderer startup on the host. It doesn't yet render 3D inside a Linux guest.

Locally the boot tests use HVF and take seconds. GitHub's macOS runners are VMs without nested virtualization, so there they use TCG emulation, which is slower but still well within the timeout.

## One-time repository setup

In **Settings → Actions → General → Workflow permissions**:
- select **Read and write permissions**;
- tick **Allow GitHub Actions to create and approve pull requests**.

Without these, the nightly job can't push branches or open PRs. If `main` has branch protection that requires reviews or status checks, the automatic merge fails and the PR stays open for a manual merge.
