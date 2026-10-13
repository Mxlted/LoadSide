# Release process

A release candidate is ready for evaluation when automated tests pass and local universal artifacts can be built. It becomes a public release only after the qualification below. No release has been published from this repository yet.

## Automated gate

Run `scripts/check.sh` on a clean checkout. CI is configured to run tests and CLI checks on Apple silicon and Intel macOS runners, then package a universal local build. Workflows pin official GitHub Actions to commit hashes; Dependabot is configured to track updates. GitHub execution remains unverified until a remote is configured and the workflows run. A green compile is not evidence of successful device installation. See [delivery status](STATUS.md) for current local test and credential-backed signing evidence.

The version lives in `VERSION`. Keep the CLI version, UI version, `CHANGELOG.md`, and bundle metadata consistent. Commit all source and documentation changes before tagging. Never include customer archives or signing material in a fixture or artifact.

## Device qualification gate

Record the exact commit, macOS version, Xcode version, device model/OS, distribution type, and sanitized result for each applicable case:

- [ ] Decrypted app without extensions: import P12, sign, export, install, and launch.
- [ ] Local Library: fresh Automatic HTTPS helper download, Safari installation through both the HTTPS link and local HTTP catalog, large IPA transfer, cancellation/quit cleanup, interrupted network, and restart link rotation. Verify My HTTPS server and Local downloads only independently. Repeat on minimum macOS and both helper architectures.
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
- [ ] macOS 14 minimum-version launch, current macOS launch, Intel and Apple silicon.
- [ ] VoiceOver, keyboard-only workflow, minimum window size, light/dark preference, Reduce Transparency, Reduce Motion, and long file/error names. Verify macOS 26+ glass controls and earlier-macOS fallbacks.
- [ ] Extension policy checkboxes: exactly one selected on launch, session reset, restored jobs and before signing; selection cannot be cleared by clicking the active checkbox.

Real Apple credentials and authorized IPA/device fixtures are necessary. Self-signed certificates and synthetic Mach-O fixtures establish individual mechanics, not device trust. Store sensitive qualification data outside this repository.

## Local evaluation build

```sh
scripts/package.sh --local
open dist/LoadSide.app
dist/loadside version
```

This maintains one ad-hoc signed universal app at `dist/LoadSide.app`. `dist/loadside` links to the CLI inside that app, so the two entry points always refer to the same build. A verified new package replaces the previous local app. Packaging does not produce a ZIP by default.

For CI or an explicit local distribution archive, run `scripts/package.sh --local --archive`. It additionally emits `LoadSide-<version>-macOS-universal-local.zip` and its checksum; existing archives and checksums are never overwritten. `--skip-build` is available only for local mode and still checks both required architecture slices and verifies the packaged signatures.

Both `check.sh` and `package.sh` use the selected Xcode macOS SDK for compilation and explicitly pass its root to clang's link driver. This works around [Swift's SDK forwarding issue](https://github.com/swiftlang/swift-package-manager/issues/8886), which can stamp the deployment target as the linked SDK and suppress the current native control appearance. Each binary slice must report macOS 14 as its minimum and the actual selected SDK as its build SDK. Stale binaries are rejected even with `--skip-build`; rebuild normally after changing Xcode. This does not raise the app's minimum macOS version.

The build is not notarized and should not be presented as a production download. Gatekeeper may require explicit local approval if the artifact has quarantine metadata.

Automatic HTTPS downloads its optional cloudflared helper on demand. When changing the pinned release in `CloudflaredInstaller`, verify official archive checksums and independently hash the extracted ARM64 and Intel executables; update sizes, third-party notices, and both architecture pins together. Test a fresh install and cached reuse, tunnel readiness, stop/cancel/quit, and real HTTPS catalog/manifest/IPA transfer. A helper or tunnel smoke test does not replace the Safari/device qualification gate.

### Generated output cleanup

Run `scripts/clean.sh --dry-run` to inspect cleanup targets, then `scripts/clean.sh` to remove `.build/` and `build/`, including compiler caches and development QA scratch work. It preserves the current `dist/` app, source documentation, historical qualification records and private `test_materials/` inputs/exports. Move any temporary evidence worth retaining out of `build/` first. The next build regenerates its cache.

Use `scripts/clean.sh --include-dist` only when intentionally removing all generated output, including current packages and release archives. Keep published releases in the release archive, not in a developer checkout.

## Production build

Use a trusted release Mac, a Developer ID Application identity already installed in its keychain, and a configured `notarytool` keychain profile. Do not put Apple passwords or private keys in CI YAML. Complete device qualification first.

```sh
export LOADSIDE_SIGNING_IDENTITY='Developer ID Application: Your Organization (TEAMID)'
export LOADSIDE_NOTARY_PROFILE='loadside-release'
scripts/check.sh
scripts/package.sh --production
```

Production packaging always rebuilds both architectures, signs the helper and app with hardened runtime and a secure timestamp, verifies them, submits to Apple, requires an Accepted notarization status, staples and validates the ticket, and checks Gatekeeper before emitting the final ZIP. Production mode does not accept `--skip-build`. Existing release ZIPs and checksums are not overwritten.

The optional `Qualified release build` workflow uses a protected `production` environment on a dedicated self-hosted Mac labeled `loadside-release`. Configure required environment reviewers, the identity/profile variables, and keychain access first. Run it from the matching version tag. Supply `device_qualification` as an issue URL in this repository and `qualification_commit` as the full SHA of the selected tag's commit. Before signing, the workflow checks the URL format and repository and requires the exact commit match.

The protected environment reviewer must inspect the issue and confirm that its evidence completes the qualification matrix for that exact commit. URL and SHA validation alone do not prove that qualification is complete. The workflow uploads artifacts for review; it does not silently publish a GitHub release.

## Publish

1. Configure the intended repository remote and push reviewed commits.
2. Update this release checklist and `docs/STATUS.md` with evidence. Remove no blocker merely to meet a date.
3. Create an annotated version tag matching `VERSION` after qualification.
4. Create a draft GitHub release with the production ZIP, checksum, changelog, compatibility limits, and qualification record.
5. Download the draft asset to a separate Mac, verify its checksum and Gatekeeper status, and repeat the primary workflow.
6. Publish the reviewed release. Keep the previous release available for rollback and note any certificate/profile compatibility changes.

Do not publish an RC as stable or a local build as notarized. If signing logic regresses, withdraw the affected download and document which artifacts and workflows are impacted.
