# Local artifact qualification: 0.1.0-rc.1

Date: 2026-10-12. Classification: **local evaluation build**, not a public or device-qualified release.

## Artifact provenance

- Source commit embedded in the app: `ef0a2438f1beea3d1a1f6cd3c629846cefe602bd`.
- ZIP: `dist/LoadSide-0.1.0-rc.1-macOS-universal-local.zip` (3,166,896 bytes).
- SHA-256: `63bbc41c89bfe3cecaa941c92a777712cec8d1cf0f4ad138c2a8c3923ca2eb81`.
- App: `dist/LoadSide-0.1.0-rc.1-local/LoadSide.app`.
- GUI and CLI: ARM64 + x86_64; minimum macOS 14.0 in both slices.
- Host: Apple silicon, macOS 27.0.1 (26A434), Apple Swift 6.4.
- Signing: local ad-hoc; nested CLI and app passed strict signature verification. ZIP checksum checked after creation.

The source commit includes the application, engine, tests, release scripts and pre-packaging evidence. This later documentation-only record preserves the identity of the artifact actually tested.

## Completed checks

- Automated regression suite: 44 tests, zero failures or skips.
- Universal optimized build of GUI and CLI.
- Release CLI environment/version/help checks, invalid argument/profile/archive failures, no failed-job output, and tracked-secret exclusion checks.
- Credential-backed signing and DEB injection with the user-supplied IPA/P12/profile: 13 signed targets without injection, 14 with one benign injected library.
- Independent extraction and deep strict signature verification of both exported IPAs; embedded profile, signed app identifier, extension removal, entitlement omissions and injected load command checked.
- SHA-256 comparison proved original IPA, P12 and profile files were unchanged.
- Native app launch and visual review of Workspace, Activity, Guide, file selection and profile inspection. The packaged build's extension-removal warning and New Session defaults were checked through the native UI.
- Shell syntax, package argument rejection, output collision guards and release qualification-reference guards.

Both successful credential-backed jobs explicitly used the supplied profile's app identifier, removed the unmatched Safari extension, and selected Compatible entitlements after Strict correctly rejected unsupported capabilities. See [status](STATUS.md) for the capability omissions. Signing integration was exercised through the shared engine's CLI; a full credential-backed job was not driven through the GUI.

## Not qualified

No installation, launch or injected-library runtime behavior has been tested on an iOS device. No execution on Intel or the minimum macOS release has been tested. Certificate revocation and target-device eligibility are not established by local export verification. Developer ID signing, Apple notarization, GitHub-hosted CI execution and public release publication remain outstanding. The broader [release checklist](RELEASING.md) still applies.

Sensitive fixtures, passwords, exported third-party IPAs and detailed local logs remain outside Git. The distributable contains only LoadSide, its CLI, documentation and third-party notices.
