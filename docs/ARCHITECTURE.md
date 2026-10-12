# Architecture

## Decision: native macOS, one signing engine

LoadSide uses Swift 6 and targets macOS 14+. SwiftUI provides native file dialogs, keyboard interaction, accessibility, and a responsive desktop interface. Foundation, Security, CryptoKit, Apple's `codesign`, and system libarchive implement signing and archive operations. There are no downloaded runtime packages or embedded language runtimes.

A macOS-only first release is intentional: Apple's maintained signing tools handle current signature formats and DER entitlements. Adding another platform requires a separately qualified signing backend, not an untested replacement hidden behind the interface.

The app and CLI depend on `LoadSideCore`. `SigningRequest` is immutable job input by convention, `SigningEvent` is the progress contract, and `SigningResult` is emitted only after a verified export. UI code never decides entitlement authorization or edits binaries. Progress is derived from actual stages and code-object counts, not a timer.

## Job lifecycle

1. Validate local inputs and reserve an isolated workspace.
2. Extract the IPA with bounded streaming I/O. Reject path traversal, unsafe links, special files, collisions, malformed archives, and excessive expansion.
3. If explicitly requested, remove app-extension bundles from the staged copy and report each removal. Discover the retained application and nested code; inspect binaries for malformed structures and active encryption.
4. Validate CMS profiles and import a P12 identity into a private temporary keychain. Check expiry and exact certificate inclusion.
5. Resolve app identity using certificate-compatible profiles. Automatic mode preserves an authorized original ID or selects one unique exact replacement; Preserve forbids automatic changes and an explicit override takes precedence. Apply metadata changes, select a profile for every retained provisioned bundle, reconcile its claimed entitlements, and embed its selected profile. Surface every identity change and policy-driven omission.
6. Stage optional injection payloads. Validate dependency paths and architecture compatibility; only patch within verified Mach-O header space.
7. Re-inspect all code after injection and normalize staged executable permissions. Replace signatures explicitly from deepest to outermost; the root app is last.
8. Verify signed code and package the result. Calculate the output SHA-256 and commit to a new output path. Report success only after commit.
9. Delete temporary keychain and workspace on success, failure, or cooperative cancellation.

The engine does not execute code from imported archives. File names and subprocess output are data. Subprocesses receive argument arrays rather than interpolated shell commands.

## Entitlement policy

A provisioning profile is an authorization allowlist, not a template to copy wholesale. Existing app entitlements are reconciled against the new profile; identity entitlements are rebuilt for the selected application identifier and team. The strict policy fails on unsupported claims. The compatible policy reports dropped claims and can change app behavior. It cannot create capabilities that the profile does not authorize.

Each retained extension or companion app is a separate signing boundary. A main-app profile is not automatically valid for an extension. Extension removal is an explicit, default-off choice that removes `.appex` bundles and their features from the export; nested companion apps remain and still require matching profiles. Ambiguous profile matches fail rather than choosing based on an incidental input order.

`SigningPreflight` safely inspects an IPA in a temporary workspace before signing and supplies the client with app/extension identifiers. Its profile-only identifier suggestion lets the interface explain changes and missing extension profiles early. The engine repeats validation with the actual P12 certificate; preflight is never a substitute for authorization.

## Saved signing profiles

`SavedSigningProfileStore` is an actor owning private copies of imported P12/provisioning files, per-profile manifests, and the last selected profile. Saving validates the real identity and signed profiles before publishing a complete record. Selecting verifies saved-file integrity and profile validity again. UUID directory names, bounded regular-file reads and atomic metadata updates prevent user-visible names from becoming filesystem paths. Original imported files remain independent and unchanged.

Optional remembered passwords use a namespaced, non-synchronizable macOS Keychain generic-password item. The UI requires explicit opt-in; metadata and history contain no password. Signing private keys still use only disposable per-job keychains. Deleting a saved profile removes its managed files and remembered password. Corrupt or incomplete records are reported and preserved for explicit recovery rather than silently discarded.

## Injection contract

A DEB is a container, not an installation instruction. Only supported user-space payloads are imported. Maintainer scripts are ignored and never executed. Dependencies must resolve to supported system libraries or supplied in-app libraries; a reference to a jailbreak-only loader is not considered resolved merely because it has a familiar filename.

Load commands are edited with strict bounds checking. The engine does not move executable sections, decrypt code, invent missing dependencies, or silently truncate universal binaries. Existing code signatures are replaced after modification.

## Isolation and operational limits

Private job directories reduce accidental access and keep original inputs unchanged. Credential cleanup is guaranteed for normal completion/error/cancellation, but process kill, power loss, and filesystem failure remain operational risks. Do not interpret an in-memory Swift password string as securely zeroizable memory. The system keychain protects imported keys during use; the login keychain is not the identity destination.

Offline checks do not determine whether Apple revoked a certificate or whether the target device is currently eligible. Real device installation and launch remain release qualification steps. Profile plist interpretation follows Apple's documented diagnostic structure, which Apple explicitly reserves the right to change; tests and compatibility notes must track those changes.

## Primary references

- [Apple TN3125: provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Apple: current signature format and DER entitlements](https://developer.apple.com/documentation/xcode/using-the-latest-code-signature-format)
- [Apple: code-signing depth and verification](https://developer.apple.com/library/archive/technotes/tn2206/)
- [Apple Mach-O structures](https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h)
- [libarchive public APIs](https://github.com/libarchive/libarchive/tree/v3.7.7/libarchive)
- [Debian package format](https://manpages.debian.org/bookworm/dpkg-dev/deb.5.en.html)
