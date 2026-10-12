# Compatibility and limits

LoadSide exports signed IPAs. Installation and runtime behavior depend on Apple's provisioning rules, the app, its capabilities, and the target device. See `STATUS.md` for what has actually been tested.

## Signing inputs

| Input | Supported behavior |
| --- | --- |
| Decrypted IPA | Exactly one root `Payload/*.app`; nested apps, extensions, frameworks and Mach-O code are inspected |
| Encrypted IPA | Rejected when any executable slice has active encryption; decryption is not provided |
| P12 / PFX | One unambiguous private-key identity authorized by the supplied profiles; password entered locally |
| Profiles | Original signed Apple profiles with current dates; exact certificate inclusion and per-bundle identity matching |
| Development / Ad Hoc | Export supported; target device must be registered in the profile |
| Enterprise | Export supported when the profile authorizes all devices under the applicable distribution program |
| App Store profile | Rejected for direct installation; use an appropriate distribution profile |
| Extension / companion app | Needs a matching profile and separately resolved entitlements |
| Simulator / macOS code inside IPA | Rejected |

The default **Automatic** identifier policy preserves an authorized original identifier; otherwise it uses one unambiguous explicit identifier from certificate-compatible profiles. Multiple possible identifiers fail with guidance to choose an override. Wildcard mismatches are not resolved by inventing an identifier. Use CLI `--bundle-id-policy preserve` to prohibit automatic changes; `--bundle-id` explicitly overrides either policy. Preflight suggestions use profile metadata; the engine checks the actual selected certificate before signing.

Bundle identifier changes update the root and matching nested identifier prefixes and supported Watch references. They cannot recreate associated services, app groups, push credentials, keychain contents, or arbitrary identifiers encoded in the app's own resources or code. An explicit profile does not authorize arbitrary original identifiers: multiple exports using the same authorized identifier replace one another when installed on the same device.

**Remove app extensions** (CLI `--remove-extensions`) explicitly omits `.appex` bundles from the staged application. It defaults off. This can enable export with only a main-app profile, at the cost of extension features such as Safari integration or notification processing. Removals are recorded in diagnostics. Nested Watch/companion apps are not silently removed and still require valid profiles.

For an unsigned app with no recoverable entitlements, LoadSide derives minimum identity claims. It cannot infer the original capabilities. Supply a correctly prepared app when capabilities are required; a profile's allowlist is deliberately not copied wholesale into the app.

## Injection

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

Only one job runs at a time in the desktop app. The UI retains up to 50 local job records and bounds recorded events. Saved signing profiles retain private copies of imported P12/provisioning files. Passwords are remembered only when explicitly requested, through macOS Keychain, and never written into history or local profile metadata. Without a remembered password, re-enter it for a retry. Final export paths must be new files. No automatic certificate renewal, Apple ID login, app decryption, Windows/Linux client, or device installation is included in this release candidate.

These limits are explicit product boundaries. Device installation, capability behavior, DEB runtime operation, and minimum-macOS compatibility require the release qualification matrix; local signature verification alone is insufficient.
