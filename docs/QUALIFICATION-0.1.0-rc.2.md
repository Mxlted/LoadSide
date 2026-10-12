# Local artifact qualification: 0.1.0-rc.2

Date: 2026-10-12. Classification: **local evaluation build**, not a public or device-qualified release.

## Artifact provenance

- Source commit embedded in the app: `0b8b88b913805ee459632b3e1e3773692dbf56f5`.
- ZIP: `dist/LoadSide-0.1.0-rc.2-macOS-universal-local.zip` (3,618,897 bytes).
- SHA-256: `73b1d962c19b477a3e807206fb17d202cb6e6cc88708cd84e15a5297d95d9ea1`.
- App: `dist/LoadSide-0.1.0-rc.2-local/LoadSide.app`; bundle build number `9`.
- GUI and CLI: ARM64 + x86_64; minimum macOS 14.0 in both slices.
- Host: Apple silicon, macOS 27.0.1 (26A434), Apple Swift 6.4.
- Signing: local ad-hoc. Packaged app and helper passed strict signature verification; the ZIP checksum was independently checked.

This documentation-only record follows the source commit so it can identify the exact packaged artifact. The previous RC.1 artifact remains available.

## Completed checks

- Automated regression suite: **64 tests, zero failures or skips**, including actual Security/Keychain operations and native signing integration.
- Optimized universal GUI and CLI build; release CLI environment, version, argument, invalid input and no-partial-output checks.
- Automatic app-ID resolution with the actual supplied certificate and profile: the original app identifier is unauthorized, so the engine selects the single exact authorized identifier after checking certificate membership. Preserve mode remains an explicit choice and rejects this mismatch.
- Actual supplied Cercube 6.4.1 DEB injected into the supplied decrypted YouTube 21.41.5 IPA. Signing completed with three code objects, one injected dylib and the app-root Cercube resource bundle.
- Independent extraction of the resulting IPA; deep strict signature verification, embedded profile bytes, resulting app identifier, injected load command, absence of removed extensions and all 24 original resource files checked. Original input SHA-256 values remained unchanged.
- Real saved-profile validation using the supplied P12 and Apple-signed profile. Private copies were reused after removing temporary import copies, rebuilding the store, and reselecting. Rename/delete, private permissions, expiry, corruption recovery and native opt-in Keychain CRUD were verified.
- Native UI review covered the saved profile manager, restored identity after restart, actual IPA/DEB file pickers, visible automatic ID plan, Preserve mismatch recovery, explicit extension removal, Compatible entitlements, and New Session defaults.
- Final packaged app launched successfully and restored the saved “Personal Ad Hoc” identity. No password was remembered for this saved identity.
- Git whitespace, shell syntax and tracked-secret exclusion checks passed. Source and qualification changes are recorded in focused commits.

The Cercube export used explicit removal of six unmatched extensions and Compatible entitlements, omitting eight capabilities not authorized by the profile. See [delivery status](STATUS.md) for scope and the earlier baseline. The credential-backed signing job ran through the shared engine's CLI; it was not driven end to end through the GUI.

Private output: `build/qa-rc2/YouTube-Cercube-signed.ipa`.
SHA-256: `c613b3d1a28fbbbeabd25df6cc204f0c5d2bbdfa20252cfe2e7bec8386fbab1b`.

## Not qualified

Installation, launch, injected-library behavior and resource lookup have not been exercised on an iOS device. Local verification does not establish certificate revocation status, device eligibility or Cercube compatibility with this YouTube version. Intel execution and minimum-macOS execution remain untested. Developer ID signing, notarization, GitHub CI execution and public publication remain outstanding; no Git remote is configured.

The [release checklist](RELEASING.md) remains applicable. Credentials, passwords, original third-party inputs, exported IPAs and detailed private logs are excluded from Git and the distributable.
