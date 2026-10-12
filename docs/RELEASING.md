# Release process

A release candidate is ready for evaluation when automated tests pass and local universal artifacts can be built. It becomes a public release only after the qualification below. No release has been published from this repository yet.

## Automated gate

Run `scripts/check.sh` on a clean checkout. CI is configured to run tests and CLI checks on Apple silicon and Intel macOS runners, then package a universal local build. Workflows pin official GitHub Actions to commit hashes; Dependabot is configured to track updates. GitHub execution remains unverified until a remote is configured and the workflows run. A green compile is not evidence of successful device installation. See [delivery status](STATUS.md) for current local test and credential-backed signing evidence.

The version lives in `VERSION`. Keep the CLI version, UI version, `CHANGELOG.md`, and bundle metadata consistent. Commit all source and documentation changes before tagging. Never include customer archives or signing material in a fixture or artifact.

## Device qualification gate

Record the exact commit, macOS version, Xcode version, device model/OS, distribution type, and sanitized result for each applicable case:

- [ ] Decrypted app without extensions: import P12, sign, export, install, and launch.
- [ ] App with extension: separate valid profiles, install, launch the app, and exercise the extension.
- [ ] Keep extensions with only a main-app profile: fail with an actionable missing-profile diagnostic and no final export.
- [ ] Explicitly remove extensions: record each removal, export with matching profiles for all retained apps, verify the source IPA is unchanged, install, and confirm the main app works with extension features absent.
- [ ] Wildcard and explicit profiles; team/app-prefix handling and keychain groups.
- [ ] Automatic and Preserve app-ID policies: exact-profile rewrite, wildcard preservation, ambiguous profiles, explicit override, and correct nested identifiers.
- [ ] Save identity, relaunch, reuse with and without remembered password, deny Keychain access, rename/delete, corrupt metadata and expired saved material.
- [ ] Nested DEB resource bundles at app root: preserve bytes, reject collisions/hidden executable content, and verify actual tweak resource lookup on device.
- [ ] Compatible DEB with resources and a supplied dependency: inject, sign, install, and exercise its behavior.
- [ ] Unsatisfied tweak dependency and architecture mismatch: actionable failure before export.
- [ ] Entitlement mismatch: strict rejects; compatible produces explicit omissions and expected runtime behavior.
- [ ] Invalid password, expired/revoked certificate, expired profile, wrong team/certificate, wrong app ID, and unregistered device.
- [ ] Cancellation during extraction, signing, and export: no final partial file, private keychain removed, original inputs unchanged.
- [ ] Repeated jobs, large IPA, disk full, unreadable input, export collision, and retry after correction.
- [ ] macOS 14 minimum-version launch, current macOS launch, Intel and Apple silicon.
- [ ] VoiceOver, keyboard-only workflow, minimum window size, light/dark preference, and long file/error names.

Real Apple credentials and authorized IPA/device fixtures are necessary. Self-signed certificates and synthetic Mach-O fixtures establish individual mechanics, not device trust. Store sensitive qualification data outside this repository.

## Local evaluation build

```sh
scripts/package.sh --local
open "dist/LoadSide-$(cat VERSION)-local/LoadSide.app"
```

This creates an ad-hoc signed universal `.app`, ZIP, and checksum. The unpacked app is placed at `dist/LoadSide-$(cat VERSION)-local/LoadSide.app`, and the ZIP name includes `-local`. Existing app directories, ZIPs, and checksums are not overwritten. The build is not notarized and should not be presented as a production download. Gatekeeper may require explicit local approval if the artifact has quarantine metadata.

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
