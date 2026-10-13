# Changelog

## Unreleased

- Separate local HTTP protocol handling from listener/transfer lifecycle. Parse CRLF framing as bytes so final header values remain intact, reject malformed body declarations, and close failed transfers without appending a second HTTP response.

- Separate bundle inventory and shared IPA export transactions from signing orchestration; move reusable synthetic test fixtures into a dedicated support directory.
- Fail closed on unreadable archive/injection directories, ambiguous rootful/rootless injection aliases, and malformed signatures whose filenames mimic unsigned-code diagnostics. Preserve engine event IDs and timestamps during diagnostic redaction.

- Apply full-row expand/collapse controls throughout the app, including Help, Local Library addresses, and nested extension details. Include Help row padding in the click target.

- Make workspace option headers clickable across the row. Make the IPA card open the file chooser, rename its empty state to “Add an IPA,” and clarify that the IPA must be decrypted.

- Add automatic HTTPS setup for browser installation using SignTools’ Cloudflare tunnel approach. Download and verify a pinned official helper once, generate a temporary HTTPS link and QR code, preserve custom HTTPS/local-only choices, and close sharing on cancellation, stop, quit, or helper failure.
- Increase native text, controls, click targets, spacing, and window dimensions proportionally by about 10%; enlarge mobile catalog actions to at least 44 pixels high.

- Add a private signed-app library and an opt-in local web server with a mobile catalog, IPA downloads, and HTTPS OTA manifests/install links. Limit sharing to verified export copies and rotate access links each session.
- Add credential-free **Inject only** mode in the app and `loadside inject` CLI. Export validated but unsigned IPAs with stale signatures/profiles removed; preserve inputs and require later signing for ordinary iOS installation.
- Adapt the workspace for 16:9 displays with fixed source/mode and export controls, independent side-by-side input/settings columns, and expandable advanced details.
- Fix Keep original rejecting a main app whose metadata bundle ID differs from the supplied exact profile. Preserve the original ID while using an unambiguous profile identity for signed entitlements; show and record the mismatch. Apply the same selected profile to eligible extension reuse without requiring the preserved main ID to equal the profile ID. Keep Automatic/override behavior, certificate checks and entitlement policies unchanged.
- Preserve each app's original bundle identifier by default in the UI and CLI; profile-based Automatic resolution remains an explicit option.
- Default extension signing to experimental main-profile reuse while preferring valid matching profiles. Present the two extension policies as mutually exclusive checkboxes with one required selection, and add CLI `--require-matching-extension-profiles` to disable reuse. Keep Strict entitlements as the default.
- Ignore validated regular Finder/AppleDouble `Payload/._*.app` metadata sidecars when locating the root app, avoiding false multiple-app errors without relaxing archive path, link or file-type checks.
- Restore saved signing files without requesting Keychain access at launch; retrieve remembered passwords only when signing starts.
- Polish native navigation and signing controls with Liquid Glass where supported, retain readable content surfaces and provide earlier-macOS fallbacks.
- Consolidate local packaging into `dist/LoadSide.app` and its bundled CLI link. Make local ZIP creation explicit with `--archive`, update CI accordingly, and add cleanup tooling that preserves the current packaged app and user inputs by default.
- Correct Swift's macOS SDK forwarding at link time so native controls adopt the current system appearance, while retaining the macOS 14 deployment target. Verify the SDK and minimum OS recorded in every packaged binary slice.
- Expand the Apple-approval omission catalog to 113 exact entitlement keys researched from Apple's entitlement references and program guides. Record capability names, source URLs and distribution-only rules; preserve development-profile validation where no approval is needed. Handle HealthKit and Fonts approval-only array values separately from ordinary capabilities.
- Omit unauthorized known Apple-approval entitlements (Multicast Networking and User-Assigned Device Name) in either signing policy, retaining authorized claims. Log each omission immediately, including when another entitlement later blocks signing; keep ordinary and undocumented capability validation unchanged.
- Move signing/export progress and last-export details directly below the IPA selector.
- Fix Associated Domains authorization when an Apple profile uses a scalar `"*"` allowlist and the app requests an array of domains. Preserve the requested array in Strict and Compatible modes without broadening other entitlement types.
- Add experimental main-profile identity reuse for unmatched child extensions, following SignTools' supplied-profile compatibility approach. Prefer matching profiles and record the bundle/signing identifier mismatch and runtime limits in the app, CLI and diagnostics.
- Show missing extension IDs and supplied profile patterns with a direct Add extension profiles action. Resolve the main ID unambiguously when profiles also cover actual nested bundles.
- Fix cancellation/timeout cleanup hanging in Foundation's detached subprocess wait; wait for the termination callback before deleting temporary work.

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
