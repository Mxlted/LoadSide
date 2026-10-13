# Delivery status

**0.1.0-rc.3 — local evaluation candidate. No production release is published.**

LoadSide targets native Apple Silicon on macOS 14+. Automatic HTTPS requires macOS 15+. The public source repository is [Mxlted/LoadSide](https://github.com/Mxlted/LoadSide); production downloads remain gated on the evidence below.

## Current verification

The release-preparation review adds archive path-namespace checks, type-safe entitlement reconciliation, bounded reads of untrusted files, and session-password isolation when changing certificates. It preserves the shared engine, persisted data, CLI contracts, and existing signing policies.

The repository now has a product-focused README with genuine empty-state application captures and separate end-user guides. Release tooling verifies archive round trips, source provenance, version consistency, and non-overwriting publication. The GitHub workflows use hosted ARM64 runners for verification; production signing stays on a trusted release Mac.

On 2026-10-13, the full native XcodeBuildMCP debug build and `scripts/check.sh` passed: **195 tests** (160 core, 9 CLI, 26 app), zero failures or skips; formatting, local documentation links, shell syntax, packaging guards, optimized ARM64 build, exact deployment/SDK metadata, CLI smoke/error paths, and tracked-file hygiene. The native host was macOS 27.0.1 with Swift 6.4. Independent code review found no remaining blocking findings after correcting archive-publication cancellation cleanup. Packaging and hosted CI evidence will be recorded after their runs. Historical evidence is preserved in the [development verification log](history/2026-10.md) and [RC.1](QUALIFICATION-0.1.0-rc.1.md) / [RC.2](QUALIFICATION-0.1.0-rc.2.md) artifact records. Those records are not qualification of RC.3.

## Blocking public binary release

- Physical-device installation, app/extension runtime, injected-library behavior, and OTA transfer/install qualification for the supported policy matrix.
- Actual macOS 14 execution, current-macOS end-to-end qualification, and full accessibility checks (VoiceOver, keyboard-only use, system accessibility settings).
- Developer ID Application signing, accepted notarization, stapling, Gatekeeper assessment, and independent download testing of the exact release archive.

Use the [release checklist](RELEASING.md) to collect exact-commit evidence. Synthetic fixtures, unit tests, and local signature verification establish particular mechanics; they cannot establish Apple device trust or app runtime behavior. Do not tag or publish a production release while these gates remain open.

## Evaluation artifacts

Local packaging maintains `dist/LoadSide.app` and its bundled CLI link, `dist/loadside`. Explicit local archives are labeled `macOS-arm64-local` and are ad-hoc signed, not notarized. Source IPAs, signing material, and private qualification logs remain outside the public repository and distributables.
