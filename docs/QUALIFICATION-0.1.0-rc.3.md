# Local artifact qualification: 0.1.0-rc.3

Date: 2026-10-13. Classification: **local evaluation build**, not a production or device-qualified release.

## Artifact provenance

- Source commit: `758af93c84a3798ed5768c2fbd37e1346c5a5e67`, clean checkout.
- ZIP: `dist/LoadSide-0.1.0-rc.3-macOS-arm64-local.zip` (3,127,841 bytes).
- SHA-256: `0a9a8ef067b27435f6b7ea667b977f82acae5b637d166aaa3be8be78ea4e5693`.
- Current app: `dist/LoadSide.app`; bundled CLI link: `dist/loadside`.
- App and CLI: ARM64 only, minimum macOS 14.0, linked SDK 27.0.
- Local build: macOS 27.0.1, Apple Swift 6.4; ad-hoc signed, not notarized.

This documentation-only record follows the packaged source commit. `Contents/Resources/BuildInfo.txt` records the exact source and toolchain; it does not promise byte-identical archives across toolchains or signing runs. Earlier local evaluation snapshots were preserved separately.

## Completed verification

- Full local `scripts/check.sh`: **196 tests** (161 core, 9 CLI, 26 app), zero failures or skips. Formatting, shell syntax, documentation links, packaging guards, optimized ARM64 build, deployment/SDK metadata, CLI smoke/error paths, and tracked-file hygiene passed.
- [Hosted CI for the packaged source](https://github.com/Mxlted/LoadSide/actions/runs/38422518763): full checks, optimized build, local ARM64 packaging, and artifact upload passed on the `macos-15` Apple Silicon runner with Xcode 26.3, Swift 6.2.4, and SDK 26.2.
- ZIP integrity, extraction, strict signatures, exact architecture/deployment/SDK metadata, extracted CLI execution, and SHA-256 verification passed during packaging.
- The local archive was uploaded to the unpublished draft, downloaded again, and matched the recorded SHA-256; its ZIP integrity check passed. The separate CI-produced archive was also downloaded and verified by checksum, extracted signature, and CLI execution. Its SHA-256 is `aae19158dcd2995904ab29a09d05503a988686b58350fdfb10f35978c4b6129c`; its embedded source is the same clean commit, with the hosted toolchain above.
- The exact packaged app launched with isolated empty storage. Workspace and Help navigation and the displayed `0.1.0-rc.3` version were checked.
- Independent review covered untrusted-file reads, archive namespaces, entitlement types, certificate password isolation, listener shutdown, packaging publication, and credential boundaries. The listener regression includes 20 same-port restarts, concurrent stop calls, and stale-link rejection.
- Reachable-history and changed-file audits found no credentials or private signing material. Screenshot content and metadata were reviewed; the README's genuine app images rendered on GitHub. GitHub secret scanning and push protection are enabled.

Hosted verification exposed and resolved compiler-formatting/type-checking differences and test assumptions about platform executables, attached display size, and self-signed certificate trust. Executable signing fixtures now compile owned ARM64 code and execute it before and after extraction. Layout tests retain exact viewports without changing system display settings. Credential tests verify imported-key signatures and reject altered messages without changing system trust or keychain search lists. No tests are skipped to accommodate the hosted runner.

The synthetic credential test proves import, certificate pairing, caller key use, isolation, and cleanup. It does **not** prove external `codesign` trust/access with an Apple identity. Ad-hoc fixtures separately verify code seals, entitlements, and archive round trips.

## Outstanding qualification

- Real authorized identity signing and external `codesign` access on each qualified macOS version.
- Physical-device installation, app and extension runtime, injection behavior, and the complete OTA/sharing matrix.
- Actual macOS 14 execution and full VoiceOver, keyboard, accessibility-settings, and end-to-end desktop qualification.
- Developer ID signing, accepted notarization, stapling, Gatekeeper assessment, and independent download testing of the exact production archive.

The GitHub release remains an unpublished draft. No final version tag or production download is approved. Complete the [release checklist](RELEASING.md) before publication; a successful automated or local check cannot replace these gates.
