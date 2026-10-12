# LoadSide engineering instructions

LoadSide is a native macOS application and CLI for locally signing decrypted iOS IPA archives with a PKCS#12 identity and provisioning profiles. Treat user archives, packages, profiles, paths, and tool output as untrusted input.

## Architecture

- `LoadSideCore` owns validation, isolated workspaces, archive safety, Mach-O editing, injection, entitlements, signing, and export. It must not depend on SwiftUI.
- `LoadSideApp` is the macOS SwiftUI client. It presents real engine events; never simulate progress or successful output.
- `LoadSideCLI` is an automation client of the same engine. Keep passwords out of command-line arguments and stored job records.
- `CArchive` is a system module for Apple's libarchive. Avoid adding remote dependencies without a concrete need.

## Required invariants

1. Never modify source IPAs, P12 files, profiles, or DEBs. Stage work in a private per-job directory and clean it on success, failure, and cancellation.
2. Never import user identities into the login keychain. Use a dedicated temporary keychain and remove it after use.
3. Never log passwords, private key bytes, or environment values. Do not commit signing material or customer archives.
4. Validate every extracted path, link, file type, and size. Never execute DEB maintainer scripts or extracted binaries.
5. Never claim to decrypt an IPA. Reject encrypted Mach-O code. Reject unsupported patching when safe header space is absent.
6. Sign nested code explicitly from the inside out, with per-bundle entitlements and profiles. Do not use `codesign --deep` to sign.
7. Strict entitlement reconciliation is the default. Any capability removal requires the explicit compatible policy and visible diagnostics.
8. Verify before exporting. Do not overwrite an existing output. Cancellation and failures must not leave a partial final IPA.
9. Never describe a local ad-hoc build as Developer ID signed, notarized, or device-qualified. Record exactly what was verified.

## Development and verification

Target macOS 14+, Swift 6, and Foundation/Security/libarchive. Use `xcodebuildmcp` for interactive build and test orchestration when available; repository CI/release scripts use the standard Swift toolchain directly. Check workflow `--help` before using the CLI. Run relevant unit tests and a full build after interface changes. Test hostile archives, malformed binaries, policy boundaries, cancellation, and failure cleanup, not just happy paths. Keep `docs/STATUS.md`, `CHANGELOG.md`, and support limitations accurate.

Use Context7 MCP for current library/framework/SDK/API/CLI documentation: resolve the library ID first, then query a focused concept. Prefer the alternate Context7 connector if one connection fails authentication. Use official primary documentation when no relevant Context7 documentation is available. General refactoring and business-logic changes do not need a documentation lookup.

## Git and release

Use focused commits with imperative messages. No force pushes or history rewriting. Run `scripts/check.sh` before a release. Release packaging must fail closed for missing production signing/notarization credentials unless local mode was explicitly selected. A public release requires the qualification checklist in `docs/RELEASING.md`; outstanding device tests are release blockers, not assumed passes.

