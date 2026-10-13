# Release process

A release candidate is ready for evaluation when automated tests pass and local ARM64 artifacts can be built. It becomes a public release only after the qualification below. No release has been published from this repository yet.

## Automated gate

Run `scripts/check.sh` on a clean checkout. CI is configured to run tests and CLI checks on an Apple Silicon macOS runner, then package an ARM64 local build. Workflows pin official GitHub Actions to commit hashes; Dependabot tracks updates. Confirm a successful run for the release commit in [GitHub Actions](https://github.com/Mxlted/LoadSide/actions); a local pass does not establish hosted-runner success. A green compile is not evidence of successful device installation. See [delivery status](STATUS.md) for current local test and credential-backed signing evidence.

The version lives in `VERSION`. Keep the CLI version, UI fallback version, `CHANGELOG.md`, and `Assets/Info.plist` consistent. Use `MAJOR.MINOR.PATCH` with an optional prerelease suffix such as `-rc.3`; prereleases must stay marked as prereleases on GitHub. Packaging rejects malformed versions and stale CLI binaries. Full Git history is required because the bundle build number is the commit count; CI uses `fetch-depth: 0`. Commit all source and documentation changes before tagging. Never include customer archives or signing material in a fixture or artifact.

## Device qualification gate

Record the exact commit, macOS version, Xcode version, device model/OS, distribution type, and sanitized result for each applicable case:

- [ ] Decrypted app without extensions: import P12, sign, export, install, and launch.
- [ ] With a real authorized identity on each qualified macOS version, verify external `codesign` access through the dedicated temporary keychain without changing the user's trust settings, default keychain, or search list. Synthetic key-operation tests do not establish this trust/access boundary.
- [ ] Local Library: fresh Automatic HTTPS helper download, Safari installation through both the HTTPS link and local HTTP catalog, large IPA transfer, cancellation/quit cleanup, interrupted network, and restart link rotation. Verify My HTTPS server and Local downloads only independently. Verify local/custom HTTPS on macOS 14, the Automatic HTTPS compatibility diagnostic on macOS 14, and all sharing modes on macOS 15+ Apple Silicon.
- [ ] App with extension: separate valid profiles, install, launch the app, and exercise the extension.
- [ ] Require matching extension profiles with only a main-app profile: fail with an actionable missing-profile diagnostic and no final export.
- [ ] Default experimental main-profile reuse: preserve child extension IDs, record the exact signing-identity mismatch, install, launch and exercise retained extensions. Verify matching profiles still take priority and nested companion apps cannot use the fallback.
- [ ] Explicitly remove extensions: record each removal, export with matching profiles for all retained apps, verify the source IPA is unchanged, install, and confirm the main app works with extension features absent.
- [ ] Wildcard and explicit profiles; team/app-prefix handling and keychain groups.
- [ ] Preserve app-ID default and explicit Automatic policy: keep original metadata IDs with an exact profile's separate signing identity, record mismatches, reject ambiguous/wrong-certificate profiles, verify matching wildcards and explicit overrides, and check nested identifiers. Install and exercise the preserved-ID output; Automatic remains an explicit metadata rewrite.
- [ ] Save identity, relaunch, reuse with and without remembered password, deny Keychain access, rename/delete, corrupt metadata and expired saved material.
- [ ] Nested DEB resource bundles at app root: preserve bytes, reject collisions/hidden executable content, and verify actual tweak resource lookup on device.
- [ ] Compatible DEB with resources and a supplied dependency: inject, sign, install, and exercise its behavior.
- [ ] Unsatisfied tweak dependency and architecture mismatch: actionable failure before export.
- [ ] Entitlement mismatch: strict rejects; compatible produces explicit omissions and expected runtime behavior.
- [ ] Invalid password, expired/revoked certificate, expired profile, wrong team/certificate, wrong app ID, and unregistered device.
- [ ] Cancellation during extraction, signing, and export: no final partial file, private keychain removed, original inputs unchanged.
- [ ] Repeated jobs, large IPA, disk full, unreadable input, export collision, and retry after correction.
- [ ] macOS 14 minimum-version launch and current macOS launch on Apple Silicon.
- [ ] VoiceOver, keyboard-only workflow, minimum window size, light/dark preference, Reduce Transparency, Reduce Motion, and long file/error names. Verify macOS 26+ glass controls and earlier-macOS fallbacks.
- [ ] Extension policy checkboxes: exactly one selected on launch, session reset, restored jobs and before signing; selection cannot be cleared by clicking the active checkbox.

Real Apple credentials and authorized IPA/device fixtures are necessary. Self-signed certificates and synthetic Mach-O fixtures establish individual mechanics, not device trust. Store sensitive qualification data outside this repository.

## Local evaluation build

```sh
scripts/package.sh --local
open dist/LoadSide.app
dist/loadside version
```

This maintains one ad-hoc signed ARM64 app at `dist/LoadSide.app`. `dist/loadside` links to the CLI inside that app, so the two entry points always refer to the same build. A verified new package replaces the previous local app. Packaging does not produce a ZIP by default.

For CI or an explicit local distribution archive, run `scripts/package.sh --local --archive`. It emits `LoadSide-<version>-macOS-arm64-local.zip` and its `.sha256` checksum. Packaging verifies ZIP integrity, extracts the generated archive, checks every Mach-O, verifies the extracted signature, and smoke-tests the extracted CLI version before publishing the files. Existing archives and checksums are never overwritten; a failed publication removes only files created by that attempt.

`--skip-build` updates only the local app and cannot be combined with `--archive`. It still verifies SDK metadata, signatures, and version consistency, but those checks cannot establish which source commit produced existing binaries. The app's `LoadSideCommit` is therefore `unverified`; `BuildInfo.txt` records the current packaging checkout separately and labels the binary source and original compiler as unverified. Use normal packaging for any candidate requiring exact source provenance.

The bundled `Contents/Resources/BuildInfo.txt` records the version, commit, clean/modified source state, build type, architecture, SDK, minimum macOS, and compiler. This is build provenance, not a claim of bit-for-bit reproducibility: timestamps, signatures, notarization, and ZIP metadata can differ across builds. Python 3 is required for offline documentation checks and exclusive artifact publication; the selected Xcode command-line tools provide it.

Both `check.sh` and `package.sh` use the same warning-as-error flags, avoiding a redundant release rebuild after checks. They use the selected Xcode macOS SDK for compilation and explicitly pass its root to clang's link driver. This works around [Swift's SDK forwarding issue](https://github.com/swiftlang/swift-package-manager/issues/8886), which can stamp the deployment target as the linked SDK and suppress the current native control appearance. Every packaged Mach-O executable must contain only ARM64 and report macOS 14 as its minimum and the actual selected SDK as its build SDK. Binaries with stale SDK metadata are rejected even with `--skip-build`; rebuild normally after changing Xcode. This does not raise the app's minimum macOS version.

The build is not notarized and should not be presented as a production download. Gatekeeper may require explicit local approval if the artifact has quarantine metadata.

Automatic HTTPS downloads its optional cloudflared helper on demand. When changing the pinned release in `CloudflaredInstaller`, verify official archive checksums and independently hash the extracted ARM64 executable; inspect its architecture and declared deployment target, and update sizes, third-party notices, and pins together. Keep the declared helper minimum and early compatibility diagnostic accurate: the current official helper requires macOS 15; LoadSide remains macOS 14-compatible. Do not patch binary load commands or downgrade to an unsupported helper to claim older-OS support. Test a fresh install and cached reuse, tunnel readiness, stop/cancel/quit, and real HTTPS catalog/manifest/IPA transfer. A helper or tunnel smoke test does not replace the Safari/device qualification gate.

### Generated output cleanup

Run `scripts/clean.sh --dry-run` to inspect cleanup targets, then `scripts/clean.sh` to remove `.build/` and `build/`, including compiler caches and development QA scratch work. It preserves the current `dist/` app, source documentation, historical qualification records and private `test_materials/` inputs/exports. Move any temporary evidence worth retaining out of `build/` first. The next build regenerates its cache.

Use `scripts/clean.sh --include-dist` only when intentionally removing all generated output, including current packages and release archives. Keep published releases in the release archive, not in a developer checkout.

## Production build

Use a trusted Apple Silicon release Mac running a native ARM64 toolchain, a Developer ID Application identity already installed in its keychain, and a configured `notarytool` keychain profile. Do not put Apple passwords or private keys in CI YAML. Complete device qualification first.

```sh
export LOADSIDE_SIGNING_IDENTITY='Developer ID Application: Your Organization (TEAMID)'
export LOADSIDE_NOTARY_PROFILE='loadside-release'
scripts/check.sh
scripts/package.sh --production
```

Production packaging always rebuilds the ARM64 app and CLI, signs the helper and app with hardened runtime and a secure timestamp, verifies them, submits to Apple, requires an Accepted notarization status, staples and validates the ticket, and checks Gatekeeper before emitting the final ZIP. Production mode does not accept `--skip-build`. Existing release ZIPs and checksums are not overwritten.

### GitHub candidate verification

The manually dispatched **Verify release candidate** workflow runs on an ephemeral GitHub-hosted ARM64 Mac. Supply `device_qualification` as a qualification issue URL in this repository and `qualification_commit` as the full SHA of the selected ref. It checks the exact commit and URL format, runs the complete verification suite, and creates an explicitly local evaluation ZIP with checksums and a candidate record. If run from a tag, that tag must match `VERSION`.

The workflow validates the reference, not the issue contents. A maintainer must review the evidence and complete every applicable matrix item before production signing. Use the release qualification issue template to record sanitized results. The hosted workflow never receives signing credentials, notarizes, creates tags, or publishes a release.

Keep Developer ID and notarytool credentials on the trusted release Mac. Do not register a signing Mac as an unrestricted runner for this public repository: [GitHub warns that self-hosted runners can be persistently compromised by untrusted workflow code](https://docs.github.com/en/actions/reference/security/secure-use#hardening-for-self-hosted-runners). If signing is automated later, review runner isolation, restricted workflow access, ephemeral credentials, and protected environments before enabling it.

## Publish

1. Push reviewed commits to [Mxlted/LoadSide](https://github.com/Mxlted/LoadSide) and require a successful CI run for the exact release commit.
2. Update this release checklist and `docs/STATUS.md` with evidence. Remove no blocker merely to meet a date.
3. Create an annotated `v<VERSION>` tag after qualification; confirm it resolves to the qualified commit. Never move an existing published tag.
4. Run production packaging from that clean, fully fetched commit. Create a draft GitHub release with the production ZIP, checksum, user-facing notes, compatibility limits, and qualification record. Start from the candidate notes in `docs/releases/`; keep prerelease versions marked as prereleases. Do not attach local CI artifacts.
5. Download the draft ZIP and checksum to a separate Mac. Run `shasum -a 256 -c LoadSide-<version>-macOS-arm64.zip.sha256`, extract the app, confirm its stapled ticket and Gatekeeper assessment, and repeat the primary workflow using authorized fixtures. Record the actual download hash and results.
6. Publish the reviewed release. Keep the previous release available for rollback and note any certificate/profile compatibility changes.

Do not publish an RC as stable or a local build as notarized. If signing logic regresses, withdraw the affected download and document which artifacts and workflows are impacted.

Production signing follows [Apple’s notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution): Developer ID, hardened runtime, a secure timestamp, notarization, and a stapled ticket. A source repository and a release-notes draft can be public while a downloadable application remains blocked by qualification.
