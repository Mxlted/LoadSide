# Delivery status

**0.1.0-rc.3: experimental prerelease. Ad-hoc signed and not notarized.**

LoadSide targets native Apple Silicon on macOS 14+. Automatic HTTPS requires macOS 15+. The public source repository is [Mxlted/LoadSide](https://github.com/Mxlted/LoadSide); [prerelease downloads](https://github.com/Mxlted/LoadSide/releases/tag/v0.1.0-rc.3) are provided for evaluation. Production qualification remains gated on the evidence below.

## Current verification

The release-preparation review adds archive path-namespace checks, type-safe entitlement reconciliation, bounded reads of untrusted files, session-password isolation when changing certificates, and coordinated listener shutdown before restarting local sharing. It preserves the shared engine, persisted data, CLI contracts, and existing signing policies.

The repository now has a product-focused README with genuine empty-state application captures and separate end-user guides. Release tooling verifies ZIP extraction and read-only DMG mounting, source provenance, version consistency, signatures, bundled CLI execution, and non-overwriting publication. Both formats include SHA-256 checksums. The GitHub workflows use hosted ARM64 runners for verification; production signing stays on a trusted release Mac.

On 2026-10-13, native builds and `scripts/check.sh` passed with **196 tests** (161 core, 9 CLI, 26 app), zero failures or skips; formatting, documentation links, shell syntax, packaging guards, optimized ARM64 build, deployment/SDK metadata, CLI smoke/error paths, and tracked-file hygiene. The local host was macOS 27.0.1 with Swift 6.4. [Initial RC.3 hosted CI](https://github.com/Mxlted/LoadSide/actions/runs/38422518763) also passed the full check, packaging, and artifact upload on macOS 15 with Xcode 26.3. Independent review found no remaining blocking code findings.

The [RC.3 qualification record](QUALIFICATION-0.1.0-rc.3.md) preserves the initial evaluation snapshot and remaining production gates. Published artifacts carry their exact source and toolchain in `Contents/Resources/BuildInfo.txt`, with a matching SHA-256 asset on the release page. [CI runs](https://github.com/Mxlted/LoadSide/actions/workflows/ci.yml) record checks for each commit. Historical evidence remains in the [development verification log](history/2026-10.md) and [RC.1](QUALIFICATION-0.1.0-rc.1.md) / [RC.2](QUALIFICATION-0.1.0-rc.2.md) records. Those earlier records do not qualify RC.3.

## Outstanding production qualification

- Physical-device installation, app/extension runtime, injected-library behavior, and OTA transfer/install qualification for the supported policy matrix.
- Real authorized identity signing and external `codesign` access on each qualified macOS version; synthetic imported-key tests do not establish certificate trust.
- Actual macOS 14 execution, current-macOS end-to-end qualification, and full accessibility checks (VoiceOver, keyboard-only use, system accessibility settings).
- Developer ID Application signing, accepted notarization, stapling, Gatekeeper assessment, and independent download testing of the exact release archive.

Use the [release checklist](RELEASING.md) to collect exact-commit evidence. Synthetic fixtures, unit tests, and local signature verification establish particular mechanics; they cannot establish Apple device trust or app runtime behavior. Do not tag or publish a production release while these gates remain open.

## Evaluation artifacts

Local packaging maintains `dist/LoadSide.app` and its bundled CLI link, `dist/loadside`. The prerelease provides a drag-to-Applications DMG and a ZIP with matching checksums. These artifacts are labeled `macOS-arm64-local` and are ad-hoc signed, not notarized. Source IPAs, signing material, and private qualification logs remain outside the public repository and distributables.
