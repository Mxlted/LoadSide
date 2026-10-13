# Architecture

## Decision: native macOS, one signing engine

LoadSide uses Swift 6 and targets Apple Silicon Macs running macOS 14+. The app, CLI, and optional tunnel helper are ARM64-only. SwiftUI provides native file dialogs, keyboard interaction, accessibility, and a responsive desktop interface. Foundation, Security, CryptoKit, Apple's `codesign`, and system libarchive implement signing and archive operations. There are no downloaded runtime packages or embedded language runtimes.

Host architecture and archive architecture are separate contracts. Build scripts share one native ARM64 configuration; unsupported hosts and compilation targets fail early. Packaged Mach-O executables must contain exactly ARM64 and retain the macOS 14 deployment target. Universal/fat parsing and editing, per-slice validation, and payload architecture compatibility remain unchanged, including Intel slice inspection. No code from user archives is executed. macOS availability checks remain necessary regardless of CPU architecture.

A macOS-only first release is intentional: Apple's maintained signing tools handle current signature formats and DER entitlements. Adding another platform requires a separately qualified signing backend, not an untested replacement hidden behind the interface.

The app and CLI depend on `LoadSideCore`. `SigningRequest` is immutable job input by convention, `SigningEvent` is the progress contract, and `SigningResult` is emitted only after a verified export. UI code never decides entitlement authorization or edits binaries. Progress is derived from actual stages and code-object counts, not a timer.

## Source organization

The three Swift targets remain the main architectural boundaries. Inside Core, `SigningEngine` and `InjectionEngine` coordinate their distinct workflows; `BundleInventory` owns staged bundle discovery and metadata, and `IPAExport` owns shared validation, hashing, and exclusive output publication. Neither inventory nor unsigned export depends on signing orchestration. `Archive` and `Injection` propagate directory traversal failures rather than silently omitting unreadable content.

The sharing layer separates `LocalAppServer` listener/connection lifecycle and response delivery from `LocalHTTP` request, route, range, manifest, and catalog logic. A connection emits at most one HTTP response: a transfer failure after headers closes the connection rather than appending an error response to IPA bytes.

The desktop app keeps orchestration in `WorkspaceModel` and `LocalLibraryModel`, view composition in the view files, and compatible history records/persistence in `JobRecord` and `JobHistoryStore`. `SigningOptionsView` renders signing policy controls with expansion bindings owned by `WorkspaceView`, preserving disclosure state across workflow and layout changes. Model constructors accept stores while retaining the same production defaults, allowing hosted UI tests to use isolated directories and in-memory passwords. Initial-load tasks can be awaited before test fixture cleanup. The CLI keeps argument parsing separate from command execution and shares progress/result serialization and cancellation handling. Core, hosted UI/app-persistence, and CLI tests exercise these boundaries independently. See the [contributor source map](../CONTRIBUTING.md#finding-the-right-code) for entry points.

## Job lifecycle

1. Validate local inputs and reserve an isolated workspace.
2. Extract the IPA with bounded streaming I/O. Reject path traversal, unsafe links, special files, collisions, malformed archives, and excessive expansion.
3. If explicitly requested, remove app-extension bundles from the staged copy and report each removal. Discover the retained application and nested code; inspect binaries for malformed structures and active encryption.
4. Validate CMS profiles and import a P12 identity into a private temporary keychain. Check expiry and exact certificate inclusion.
5. Resolve metadata and signing identity using certificate-compatible profiles. Preserve is the default and forbids automatic metadata changes; if the original ID has no match, select one unambiguous exact main-profile signing identity while retaining the original metadata ID. Explicit Automatic mode preserves an authorized original ID or selects one unique exact metadata replacement. An explicit authorized override takes precedence. Apply requested metadata changes, select a profile for every retained provisioned bundle, reconcile its claimed entitlements, and embed its selected profile. Surface every identity change, metadata/signature mismatch and policy-driven omission.
6. Stage optional injection payloads. Validate dependency paths and architecture compatibility; only patch within verified Mach-O header space.
7. Re-inspect all code after injection and normalize staged executable permissions. Replace signatures explicitly from deepest to outermost; the root app is last.
8. Verify signed code and package the result. Calculate the output SHA-256 and commit to a new output path. Report success only after commit.
9. Delete temporary keychain and workspace on success, failure, or cooperative cancellation.

The engine does not execute code from imported archives. File names and subprocess output are data. Subprocesses receive argument arrays rather than interpolated shell commands.

## Entitlement policy

A provisioning profile is an authorization allowlist, not a template to copy wholesale. Existing app entitlements are reconciled against the new profile; identity entitlements are rebuilt for the selected application identifier and team. Both policies omit and report unauthorized claims in the explicit Apple-approval catalog. The default strict policy fails on other unsupported claims. The compatible policy reports dropped claims and can change app behavior. It cannot create capabilities that the profile does not authorize.

Metadata identity and signing identity are separate values in the preflight plan: `effectiveIdentifier` is the retained or deliberately changed main bundle ID; `profileBundleIdentifier` is the ID used to select an authorized signing identity. In Preserve mode they may differ when an unambiguous exact profile is selected. The signature uses that profile's authorized `application-identifier`, with reconciled claims rather than a wholesale copy of the profile. This independently implements the supplied-profile compatibility approach used by SignTools. Automatic and explicit override policies still require a profile-authorized metadata ID.

Each retained extension or companion app is a separate signing boundary. Matching profiles always take priority. Experimental main-profile reuse is the default fallback for eligible child extensions: it retains the extension bundle ID but uses the exact main profile signing identity and reports the mismatch. Extension eligibility follows the main metadata bundle ID, including when that differs from the selected exact profile identity. This is not device-qualified and never bypasses certificate, validity, platform, distribution or entitlement checks. Nested apps cannot use this fallback. Extension removal is an explicit, default-off choice that removes `.appex` bundles and their features from the export; nested companion apps remain and still require matching profiles. Ambiguous profile matches fail rather than choosing based on an incidental input order.

`SigningPreflight` safely inspects an IPA in a temporary workspace before signing and supplies the client with app/extension identifiers. Its profile-only identifier suggestion lets the interface explain metadata changes, signing-identity mismatches and missing extension profiles early. The engine repeats validation with the actual P12 certificate; preflight is never a substitute for authorization.

## Saved signing profiles

`SavedSigningProfileStore` is an actor owning private copies of imported P12/provisioning files, per-profile manifests, and the last selected profile. Saving validates the real identity and signed profiles before publishing a complete record. Selecting verifies saved-file integrity and profile validity again. The app passes `loadPassword: false` during startup and selection, then retrieves a remembered password only when the user begins signing; this keeps Keychain prompts out of ordinary navigation. UUID directory names, bounded regular-file reads and atomic metadata updates prevent user-visible names from becoming filesystem paths. Original imported files remain independent and unchanged.

Optional remembered passwords use a namespaced, non-synchronizable macOS Keychain generic-password item. The UI requires explicit opt-in; metadata and history contain no password. Signing private keys still use only disposable per-job keychains. Deleting a saved profile removes its managed files and remembered password. Corrupt or incomplete records are reported and preserved for explicit recovery rather than silently discarded.

`CFileKeychain` is a small compatibility boundary for creating, unlocking, and deleting private file keychains and constructing two fixed trusted-application ACLs. Temporary signing keys trust the caller and `/usr/bin/codesign`; remembered passwords trust only the caller. Swift retains ownership of validation, explicit import destinations, cleanup, and the existing saved-password service/account schema. The adapter never changes the default keychain or search list.

Apple's [macOS Keychain guidance](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) and [access-policy reference](https://developer.apple.com/documentation/security/ksecattraccess) distinguish file-based Keychain ACLs from the entitlement-based data-protection keychain. The latter cannot replace a disposable keychain passed to `codesign --keychain`; `SecItem` has no equivalent file-keychain lifecycle or trusted-application ACL constructor. The necessary deprecated calls therefore remain confined to this C implementation with a local diagnostic waiver. Repository checks reject Swift warnings and C deprecations elsewhere. Revisit the boundary when equivalent supported APIs become available; changing storage backends requires separate compatibility and isolation qualification.

## Injection contract

A DEB is a container, not an installation instruction. Only supported user-space payloads are imported. Maintainer scripts are ignored and never executed. Dependencies must resolve to supported system libraries or supplied in-app libraries; a reference to a jailbreak-only loader is not considered resolved merely because it has a familiar filename.

Load commands are edited with strict bounds checking. The engine does not move executable sections, decrypt code, invent missing dependencies, or silently truncate universal binaries. Existing code signatures are replaced after modification.

## Isolation and operational limits

`InjectionEngine` shares archive, injection and export validation with the signing flow while producing a distinct `InjectionExportResult`. It never constructs a signing identity or requests credentials. Old signatures and embedded profiles are removed explicitly; the resulting archive is labelled unsigned and requires later signing.

`LocalAppLibrary` owns private UUID-named copies of successful signing exports. Copying and serving bind the IPA to its recorded SHA-256; bounded metadata and file-descriptor-based access reject links and changed contents. `LocalAppServer` uses Apple's Network framework to serve a read-only catalog, streamed IPA downloads, and generated OTA manifests. A fresh per-session token scopes every route. HTTP parsing and concurrent connections are bounded. HTTPS install links use either a supplied reverse-proxy origin or an explicitly started managed Cloudflare Quick Tunnel. `CloudflaredInstaller` pins one official ARM64 release archive and executable hash pair, bounds and verifies download/extraction, and atomically retains a private helper copy. Verification reuses one bounded 64 KiB buffer with cancellation and descriptor metadata checks. The pinned upstream executable declares macOS 15; its installer rejects older systems before storage/download work, while local/custom HTTPS sharing and LoadSide itself retain macOS 14 support. `LocalAppTunnel` launches that helper without a shell or inherited configuration, accepts only a valid trycloudflare origin plus a registered-connection event, and bounds startup and diagnostics. Cancellation, normal app termination, and unexpected helper exit stop sharing and clean temporary work. A ready HTTPS origin attaches to the existing listener only when its original session token still matches. Signing remains local, and no public manifest proxy is used. The server accepts no browser uploads or signing requests.

Private job directories reduce accidental access and keep original inputs unchanged. Credential cleanup is guaranteed for normal completion/error/cancellation, but process kill, power loss, and filesystem failure remain operational risks. Do not interpret an in-memory Swift password string as securely zeroizable memory. The system keychain protects imported keys during use; the login keychain is not the identity destination.

Offline checks do not determine whether Apple revoked a certificate or whether the target device is currently eligible. Real device installation and launch remain release qualification steps. Profile plist interpretation follows Apple's documented diagnostic structure, which Apple explicitly reserves the right to change; tests and compatibility notes must track those changes.

## Primary references

- [Apple TN3125: provisioning profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Apple: current signature format and DER entitlements](https://developer.apple.com/documentation/xcode/using-the-latest-code-signature-format)
- [Apple: code-signing depth and verification](https://developer.apple.com/library/archive/technotes/tn2206/)
- [Apple Mach-O structures](https://github.com/apple-oss-distributions/xnu/blob/main/EXTERNAL_HEADERS/mach-o/loader.h)
- [libarchive public APIs](https://github.com/libarchive/libarchive/tree/v3.7.7/libarchive)
- [Debian package format](https://manpages.debian.org/bookworm/dpkg-dev/deb.5.en.html)
