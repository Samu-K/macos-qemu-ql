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
3. **Sign.** `install_name_tool` invalidates code signatures, so every Mach-O file is signed again, with the hardened
   runtime. See [Signing and notarization](#signing-and-notarization).
4. **Licenses.** Collected from the component sources and the Homebrew kegs. For ANGLE, `gn desc` lists the
   `third_party` code `libEGL`/`libGLESv2` link, and each `README.chromium` names the license file.
5. **Notarize.** Only with a Developer ID and notary credentials.
6. **Archive.** Writes an xz tarball with no AppleDouble files or extended attributes.

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
- every code signature verifies and uses the hardened runtime;
- `qemu-system-aarch64` has the hypervisor and JIT entitlements;
- when `SIGN_IDENTITY` is a Developer ID: the package is signed with a Developer ID, library validation is on, and
  Apple's notary service knows every file (an online check);
- QEMU's firmware search path (`-L help`) is inside the package;
- in the `gl=es` boot, nothing is loaded from Homebrew or this repository's build tree (`vmmap`), and ANGLE comes from
  the package.

`scripts/ci.sh` runs `package` and `test-package` as its last two stages. CI uploads the tarball as the `package`
artifact.

## Signing and notarization

`SIGN_IDENTITY` selects the signing identity. It defaults to `-`, ad hoc.

Every file is signed with the hardened runtime, which notarization requires. QEMU's system emulators get these
entitlements (`entitlements()` in `package.sh`):

| Entitlement | Binaries | Why |
|---|---|---|
| `com.apple.security.hypervisor` | `qemu-system-aarch64` | HVF |
| `com.apple.security.cs.allow-jit` | `qemu-system-*` | TCG's code buffer is `MAP_JIT` memory |
| `com.apple.security.device.audio-input` | `qemu-system-*` | audio capture with `-audiodev coreaudio` |
| `com.apple.security.cs.disable-library-validation` | all of `bin/`, **ad hoc only** | ad hoc signatures have no team ID, and library validation only accepts the binary's own team |

Ad hoc packages use the hardened runtime too. That way CI runs the tests under the same restrictions a release has;
CI uses TCG, so this covers the JIT entitlement.

With a `Developer ID Application` identity, the files also get a secure timestamp. The staged directory is then
zipped and submitted to Apple's notary service, and `package.sh` waits for the result. A rejection fails the
build and prints the notary log. Bare executables can't carry a stapled ticket, so Gatekeeper checks the
notarization online the first time a quarantined binary runs.

### Signing locally

Requires a `Developer ID Application` certificate in the login keychain (`security find-identity -v -p codesigning`)
and notary credentials stored once in the keychain:

```sh
xcrun notarytool store-credentials macos-qemu-gl \
    --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>

SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=macos-qemu-gl scripts/package.sh
SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" scripts/test.sh --package dist/<name>-macos-arm64.tar.xz
```

### Signing in the release workflow

`release.yml` signs and notarizes when these repository secrets exist (Settings → Secrets and variables → Actions).
Without them, the release is signed ad hoc and the run shows a warning.

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12` | the Developer ID Application certificate and private key, exported from Keychain Access as `.p12`, then `base64 -i cert.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `NOTARY_KEY_P8` | contents of the App Store Connect API key file `AuthKey_<id>.p8` |
| `NOTARY_KEY_ID` | that key's ID |
| `NOTARY_ISSUER_ID` | the issuer ID shown above the key list |

With the files at hand, `gh` sets them:

```sh
base64 -i cert.p12 | gh secret set MACOS_CERTIFICATE_P12
gh secret set MACOS_CERTIFICATE_PASSWORD           # prompts for the value
gh secret set NOTARY_KEY_P8 <AuthKey_XXXXXXXXXX.p8
gh secret set NOTARY_KEY_ID --body XXXXXXXXXX
gh secret set NOTARY_ISSUER_ID --body <issuer-uuid>
```

How to get them:
- **Certificate:** in Xcode → Settings → Accounts → Manage Certificates → + → *Developer ID Application*. Only the
  team's Account Holder can create one.
- **API key:** in App Store Connect → Users and Access → Integrations → Team Keys, create a key with the *Developer*
  role. The `.p8` file can be downloaded only once.

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

Releases are tagged `v<qemu version>-<n>`, for example `v11.1.3-1`. `<n>` starts at 1 for each QEMU version and goes
up for releases that change only other components or patches.

To release the current `main`, run the **Release** workflow from the Actions tab, or:

```sh
gh workflow run release.yml --ref main                # build, publish, update the tap
gh workflow run release.yml --ref main -f draft=true  # stop at a draft release
```

`.github/workflows/release.yml` then:
1. Picks the next tag: `v<qemu version>-<n+1>`, where `<n>` is the highest existing tag or release for the pinned
   QEMU version.
2. Imports the signing certificate and notary key, if they're configured.
3. Runs `scripts/ci.sh` with the source archive enabled. This signs and notarizes the package, then tests it with
   the Developer ID checks, including an online check that Apple notarized every file.
4. Creates a draft release with the tarball, the source archive and their checksums, plus generated notes listing
   component versions and install commands.
5. Publishes the release as the latest, which creates the tag on the built commit.
6. Calls `homebrew-tap.yml` to update the tap.

With `draft=true`, it stops after step 4. Publishing the draft on GitHub later runs `homebrew-tap.yml` then.

Pushing a tag `v<qemu version>-<n>` by hand also runs the workflow, for that commit and tag. The tag must match the
QEMU version in `versions.env`.

## Homebrew tap

The tap is the repository `Samu-K/homebrew-tap`; users install with `brew install samu-k/tap/qemu-gl`. Its only
content that matters is `Formula/qemu-gl.rb`, generated by `scripts/homebrew-formula.sh <tarball>`:

- It downloads the release tarball and installs it unchanged into `libexec/`, linking only the executables into
  `bin/`. QEMU resolves its own path through the symlink, so it still finds `lib/` and `share/qemu`.
- `preserve_rpath` stops Homebrew from rewriting the `@rpath` install names. A rewrite would make Homebrew re-sign
  the files ad hoc, and a Developer ID binary with library validation then refuses to load them.
- `conflicts_with "qemu"`, because both install the QEMU executables. No other dependencies: the package is
  self-contained.
- `depends_on macos:` comes from the package README's minimum macOS version.

Homebrew only loads formulae from third-party taps that are trusted. `brew install samu-k/tap/qemu-gl` works anyway,
because naming the formula in full allows it for that command, but `brew upgrade` skips an untrusted tap. The install
instructions therefore start with `brew trust samu-k/tap`.

`.github/workflows/homebrew-tap.yml` updates it. It runs when `release.yml` publishes a release, when a release is
published by hand, and manually (`gh workflow run homebrew-tap.yml -f tag=v11.1.3-1`). It only accepts the latest
release, so the tap never goes backwards. It:
1. downloads the release tarball and verifies its checksum;
2. generates the formula, then installs and tests it from a local tap with `brew style`, `brew install` and
   `brew test`;
3. checks that the installed files are identical to the tarball, so no signature was replaced;
4. commits `Formula/qemu-gl.rb` to the tap, if it changed.

To try a formula locally without publishing anything:

```sh
scripts/homebrew-formula.sh dist/<name>-macos-arm64.tar.xz "file://$PWD/dist/<name>-macos-arm64.tar.xz" >qemu-gl.rb
brew tap-new --no-git local/qemu-gl && cp qemu-gl.rb "$(brew --repository local/qemu-gl)/Formula/"
brew install local/qemu-gl/qemu-gl && brew test local/qemu-gl/qemu-gl
brew uninstall qemu-gl && brew untap local/qemu-gl
```

## One-time setup for releases

1. **Signing secrets** for `release.yml`, see [Signing in the release workflow](#signing-in-the-release-workflow).
2. **The tap repository.** Create the public repository `Samu-K/homebrew-tap` with a README, so it has a default
   branch. The workflow adds `Formula/`.
3. **`TAP_DEPLOY_KEY`**, a repository secret in this repository holding the private half of an SSH deploy key that
   has write access to the tap and nothing else. It doesn't expire. To create or replace it:

   ```sh
   ssh-keygen -t ed25519 -N '' -C homebrew-tap-deploy -f tap_key
   gh repo deploy-key add tap_key.pub -R Samu-K/homebrew-tap --allow-write --title "macos-qemu-ql releases"
   gh secret set TAP_DEPLOY_KEY -R Samu-K/macos-qemu-ql <tap_key
   rm tap_key tap_key.pub
   ```

Without `TAP_DEPLOY_KEY`, the release is still published, and the tap job fails with an error naming the secret.
Re-run it with `gh workflow run homebrew-tap.yml -f tag=<tag>` once the secret exists.

## Not done yet

- **Intel Macs.** The package is arm64 only.
