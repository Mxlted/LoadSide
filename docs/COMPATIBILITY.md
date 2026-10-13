# Compatibility and limits

LoadSide exports signed IPAs or explicitly unsigned injection-only IPAs. Installation and runtime behavior depend on Apple's provisioning rules, the app, its capabilities, and the target device. See `STATUS.md` for what has actually been tested.

## Signing inputs

| Input | Supported behavior |
| --- | --- |
| Decrypted IPA | Exactly one root `Payload/*.app`; regular Finder `._*.app` metadata sidecars are ignored after archive validation; nested apps, extensions, frameworks and Mach-O code are inspected |
| Encrypted IPA | Rejected when any executable slice has active encryption; decryption is not provided |
| P12 / PFX | One unambiguous private-key identity authorized by the supplied profiles; password entered locally |
| Profiles | Original signed Apple profiles with current dates; exact certificate inclusion and authorized signing identities; Keep original can retain a different metadata bundle ID |
| Development / Ad Hoc | Export supported; target device must be registered in the profile |
| Enterprise | Export supported when the profile authorizes all devices under the applicable distribution program |
| App Store profile | Rejected for direct installation; use an appropriate distribution profile |
| Extension / companion app | Matching profiles take priority; experimental main-profile identity reuse defaults on for child extensions only; companion apps still require matching profiles |
| Simulator / macOS code inside IPA | Rejected |

The default **Preserve** identifier policy (**Keep original** in the app) retains the app's original `CFBundleIdentifier` in metadata. A matching profile is preferred. If none matches, one unambiguous exact main-profile identity can supply the signed `application-identifier` without changing that metadata ID. The UI shows both IDs with a compatibility warning, and the engine records the mismatch. This is a supplied-profile compatibility behavior, not a guarantee of device installation or working app services. Main profile selection excludes profiles identified as belonging to actual retained nested bundles; unrelated ambiguous choices still fail. Preflight suggestions use profile metadata; the engine repeats selection with the actual certificate and checks profile authorization of signed entitlements.

Explicitly selecting **Automatic** (CLI `--bundle-id-policy automatic`) preserves an authorized original metadata identifier or changes it to one unambiguous exact identifier from certificate-compatible profiles. `--bundle-id` explicitly overrides either policy and must be profile-authorized. Neither mode receives the Keep original mismatch fallback. Wildcard mismatches are not resolved by inventing an identifier.

Bundle identifier changes update the root and matching nested identifier prefixes and supported Watch references. Keeping the original identifier leaves those metadata identifiers intact. Neither approach recreates associated services, app groups, push credentials, keychain contents, or arbitrary identifiers encoded in the app's own resources or code. A profile continues to limit the identity and capabilities placed in the signature even when metadata differs. Exports sharing a metadata bundle ID may replace one another when installed; exports sharing a signing identity may also share keychain access.

**Remove app extensions** (CLI `--remove-extensions`) explicitly omits `.appex` bundles from the staged application. It defaults off. This can enable export with only a main-app profile, at the cost of extension features such as Safari integration or notification processing. Removals are recorded in diagnostics. Nested Watch/companion apps are not silently removed and still require valid profiles.

**Reuse main profile (experimental)** is the default extension signing policy in the app and CLI. It retains unmatched child extensions while using the main profile's exact signing `application-identifier`, distinct from the extension's `CFBundleIdentifier`. Choose **Require matching profiles** (CLI `--require-matching-extension-profiles`) to disable this fallback. The app presents the two policies as mutually exclusive checkboxes and always keeps one selected. Both main-app and extension identity reuse follow the supplied-profile approach in [SignTools](https://github.com/SignTools/SignTools) and [SignTools-CI](https://github.com/SignTools/SignTools-CI/blob/8790863e64148768be9e8320c361411580d52554/sign.py#L948-L977); SignTools' developer-account flow instead obtains separate profiles from Apple. LoadSide implements the local compatibility option independently and does not add account provisioning, remote signing, or upstream code/dependencies.

This mode requires an exact main-profile identity and the same certificate. The profile ID may differ from the main app's preserved metadata bundle ID; an eligible extension must remain a child of that main metadata ID. A valid matching extension profile always wins. It never hides ambiguous profiles, matching profiles with the wrong certificate, unrelated extension identifiers or nested-app mismatches. Wildcard profiles are handled normally when they match, never forced into an exact identity fallback. Signed entitlements still come from requested claims reconciled against the profile; the profile's full allowlist is not copied. Unsupported capability removal requires **Compatible**, except for the documented Apple-approval omissions below. Identity mismatch and possible shared keychain access are recorded. Device installation, file importing, app groups and extension runtime behavior remain unverified. Do not describe a retained extension or successful signature check as a working device feature.

### Entitlements requiring Apple approval

In both **Strict** and **Compatible**, LoadSide omits known Apple-approval entitlements when the selected profile does not authorize the requested value. It preserves authorized claims and never grants unrequested capabilities. Every omission records the entitlement key, capability name, bundle and profile in the live log and, on success, the result warnings. Warnings are emitted before other entitlement validation can fail. Omitting an entitlement allows signing to continue without that capability; it does not grant access to the feature.

The researched catalog contains 113 exact keys across CarPlay, DriverKit, payments and identity, NFC/SE, alternative browsers, visionOS enterprise APIs, research and safety APIs, and other managed programs. The [full inventory](APPROVAL_ENTITLEMENTS.md) records the capability names, keys, approval scope, primary Apple sources, and review date. Family Controls, Thread credentials, Foundation Models adapters and self-service DriverKit development capabilities use distribution-only exceptions. Shared HealthKit/Fonts keys omit only their approval-required array values; ordinary values still follow Strict/Compatible.

This is an offline catalog, not a guaranteed exhaustive live inventory of Apple's private or account-specific programs. Missing authorization alone does not identify an approval requirement. Other keys, including undocumented alternate-video-decoder-selection and StoreKit request-data claims, still follow Strict/Compatible policy. App Groups, Associated Domains, identity, keychain and debugger checks are not relaxed.

For an unsigned app with no recoverable entitlements, LoadSide derives minimum identity claims. It cannot infer the original capabilities. Supply a correctly prepared app when capabilities are required; a profile's allowlist is deliberately not copied wholesale into the app.

Associated Domains may be authorized by a scalar `"*"` in Apple's profile even though the signed app claims an array of `service:domain` strings. LoadSide preserves the requested array, including supported subdomain wildcard entries; it does not copy the profile wildcard into the signature. Enabling App Groups likewise does not authorize arbitrary group IDs: the requested groups must match the profile's allowlist. Preserved domain entitlements alone do not establish functioning universal links or web credentials; the website's association file must authorize the app's signing identity.

## Injection

**Inject only** (`loadside inject`) needs no signing files and cannot produce a normally installable iOS app. It performs the same archive, binary, architecture, dependency, filter and patch-space checks, removes stale code signatures and embedded profiles, then validates and atomically exports the unsigned result. Signature-only entitlements are lost when old signatures are removed; later signing cannot recover those original capabilities from the unsigned IPA. This mode never imports an identity or executes package scripts. Unsigned exports are not included in the signed-app library.

Supported inputs are iOS-device `.dylib` files, flat `.framework` directories, and DEB packages containing compatible libraries. Supplied dylibs/frameworks are explicitly loaded by the main executable. DEB packages must provide a matching MobileSubstrate entry point; dependency-only packages are not automatically guessed as startup libraries.

Recognized DEB payload locations include rootful paths and their `/var/jb/` variants:

- `Library/MobileSubstrate/DynamicLibraries`: matching tweak dylibs and static filters.
- `usr/lib`: library dependencies.
- `Library/Frameworks`: framework dependencies.
- Adjacent `.bundle` resources and recursively discovered `.bundle` directories under `Library/Application Support`, including package-specific subdirectories.

Static bundle/executable filters are evaluated. Runtime class and OS-dependent filter conditions are rejected when they cannot be established safely before launch. No maintainer script, daemon, launch service, preference installer, or package executable is run.

Libraries must provide compatible architecture slices. Dependency/install paths are rewritten to embedded locations. Missing dependencies produce an error; LoadSide does not bundle a hooking runtime or fabricate compatibility for Substrate, Substitute, libhooker, root privileges, or jailbreak services.

Standalone DEB resource bundles are copied to the app root for main-bundle resource lookup. Resources owned by a framework remain inside that framework. Name collisions, symlinked resource bundles and executable code hidden in resource bundles are rejected. Libraries must locate their resources portably. Absolute filesystem resource references, runtime `dlopen` strings, privileged APIs, and arbitrary application behavior are not rewritten.

Mach-O edits are limited to supported thin/universal formats and verified zero-filled header capacity. If a longer load command does not fit, injection fails without shifting executable data. Rebuild the library/application with adequate header padding when you control its source.

## Operational limits

Archive extraction is bounded by default to 100,000 entries, 4 GiB per file, 16 GiB expanded data, and a 1,000× compression ratio after the small-file allowance. Bounds also apply to local injection directory inputs. Info plists, profiles, and P12 inputs are bounded. Malformed archives, escaping/dangling links, hard links, special files, and conflicting paths fail closed.

Mach-O inspection accepts files up to 512 MiB and bounds load-command data to 16 MiB to limit memory use. Resource-only `.bundle` directories remain sealed as parent-app resources, including common bundles with stale or empty executable metadata.

Common gzip, bzip2, xz, lzma and uncompressed DEB payloads use built-in system libarchive filters. Zstandard support depends on the macOS system library. A filter requiring an external program is rejected; LoadSide never shells out to install or execute an arbitrary decompressor.

Only one job runs at a time in the desktop app. The UI retains up to 50 local job records and bounds recorded events. Saved signing profiles retain private copies of imported P12/provisioning files. Passwords are remembered only when explicitly requested, through macOS Keychain, and never written into history or local profile metadata. Without a remembered password, re-enter it for a retry. Final export paths must be new files. No automatic certificate renewal, Apple ID login, app decryption, or Windows/Linux client is included in this release candidate.

## Local sharing and installation

The local catalog serves private, hash-checked copies of completed signed exports. It accepts no uploads and exposes no arbitrary filesystem routes. Starting sharing binds a local HTTP listener reachable over the network, with an unguessable per-session URL. Anyone holding that URL can download the catalog's apps; local HTTP traffic is unencrypted. Stop sharing to invalidate the session. The app must remain running, the Mac must remain reachable, and macOS/firewall local-network access must be allowed.

OTA install buttons require an explicitly configured HTTPS origin pointing to the listener through a reverse proxy. Both manifest and IPA use this origin; its certificate must be trusted by the iOS device. The app does not create a TLS certificate, install trust roots, open router ports, or launch a tunnel. Legacy history results without a recorded `CFBundleVersion` can be downloaded but receive no fabricated install metadata. See [Apple's distribution requirements](https://support.apple.com/guide/deployment/distribute-proprietary-in-house-apps-depce7cefc4d/web). A generated install link is not proof of device installation, provisioning eligibility, or runtime compatibility.

These limits are explicit product boundaries. Device installation, capability behavior, DEB runtime operation, and minimum-macOS compatibility require the release qualification matrix; local signature verification alone is insufficient.
