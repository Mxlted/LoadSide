# Changelog

## 0.1.0-rc.2 — 2026-10-12

- Resolve a unique certificate-compatible app identifier automatically, with an explicit Preserve policy and manual override. Explain profile authorization instead of failing with a generic main-app mismatch.
- Inspect app identifiers and retained extensions before export; expose changes and missing extension profiles in the signing plan.
- Add reusable signing profiles with validated private copies, rename/delete management, integrity and expiry checks, and optional macOS Keychain password storage.
- Replace the marketing-style workspace with a compact native macOS layout, system-aware appearance, restrained accent color, persistent export controls and focused signing/activity views.
- Discover DEB resource bundles nested under package-specific Application Support directories and embed them at the app root. Reject resource collisions and hidden executable content before mutation.
- Test the actual supplied Cercube DEB against the decrypted IPA in `deb_test`; record detailed verification and remaining device-runtime limits in the delivery status.

## 0.1.0-rc.1 — 2026-10-12

Initial native macOS release candidate. Not yet qualified for public production distribution.

- Add SwiftUI signing workspace, Activity history, profile inspection, and integrated recovery guidance.
- Add shared native signing engine and CLI with P12/provisioning-profile input and local IPA export.
- Keep app extensions by default and add an explicit option to remove them from the staged export, with lost-feature guidance and per-extension diagnostics.
- Validate signed Apple provisioning profiles, certificate membership/validity, bundle identifiers, and per-bundle entitlements.
- Use disposable private keychains, explicit nested-code signing, DER entitlements, and signature verification.
- Add bounded archive extraction, Mach-O inspection/patching, and supported DEB/dylib/framework injection.
- Add cancellation, bounded subprocess diagnostics, no-overwrite atomic export, and SHA-256 evidence.
- Add adversarial unit tests, native code-signing/keychain integration tests, macOS CI, universal app packaging, and notarization gates.

Validation with supplied Apple credentials confirmed strict rejection of an entitlement not authorized by the supplied profile, a successful compatible export with 13 signed code objects, and a successful benign DEB export with 14 signed code objects and one injected library. Device installation and launch, Developer ID notarization, and GitHub publication remain unverified. See [delivery status](docs/STATUS.md) for signing/export evidence and remaining qualification.
