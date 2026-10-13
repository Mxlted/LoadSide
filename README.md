# LoadSide

A native macOS workspace for signing decrypted iOS apps with your own **P12 certificate and provisioning profiles**. Select an IPA, add signing material, optionally inject compatible libraries, and export a verified IPA. Everything runs on your Mac.

**Status: 0.1.0-rc.2 — release candidate for local evaluation.** The repository contains a real signing engine, desktop app, CLI, tests, and release tooling. A local build is not a notarized public release. See [delivery status](docs/STATUS.md) for verification evidence and outstanding qualification.

## What it does

- Imports PKCS#12 signing identities into an isolated, temporary keychain.
- Checks certificate validity, signed provisioning profiles, bundle identifiers, and profile authorization for each app and extension.
- Preserves the app's original bundle identifier by default, using an unambiguous exact profile identity in the signature when needed. Previews any identifier mismatch and extension compatibility before signing. Automatic profile-based bundle ID changes remain explicit.
- Saves reusable signing profiles with private local copies of P12/provisioning files and optional password storage in macOS Keychain.
- Reconciles entitlements with a strict default. Known Apple-approval entitlements are omitted and logged when unauthorized; explicit compatible mode can drop other unsupported claims.
- Keeps app extensions by default. Matching profiles take priority; experimental main-profile identity reuse is selected for unmatched child extensions. Requiring matching profiles or removing extensions remains available.
- Extracts IPA and DEB archives with path, link, file type, and expansion limits.
- Injects supported relocatable dylibs and frameworks, updates Mach-O load commands and dependencies, and rejects unsafe or incompatible changes.
- Signs code from the inside out, verifies signatures, and atomically publishes an IPA without overwriting existing files.
- Offers **Inject only** to prepare an unsigned IPA with DEB/dylib/framework injections without a certificate or provisioning profile.
- Keeps signed exports in a private **Local Library** and serves a mobile-friendly catalog on your network, with OTA install links when a trusted HTTPS reverse proxy is configured.
- Shows real progress, cancellation, actionable errors, export history, and diagnostic reports.
- Provides the same engine through a CLI for repeatable automation.

## Requirements

- macOS 14 or later, Apple silicon or Intel.
- A decrypted IPA that you are authorized to modify.
- For signing: an Apple-issued code-signing identity with its private key in a `.p12` file and its password.
- For signing: current provisioning profiles authorizing the selected certificate, signing identity and target device/distribution method. Keeping a different metadata bundle ID has the compatibility limits below; companion apps still require matching profiles.
- Xcode with Swift 6 or newer to build from source. The packaged app uses Apple's system tools and does not need Python, Node, Homebrew, or a network service.

LoadSide does not decrypt FairPlay apps, create certificates or profiles, bypass device provisioning, or make arbitrary jailbreak tweaks compatible with stock iOS. Its web catalog hands eligible signed apps to iOS for OTA installation; device installation remains unverified. Offline validation cannot establish current revocation status. See [compatibility](docs/COMPATIBILITY.md).

## Build and run

Open `Package.swift` in Xcode for development. To build, verify, and run the current packaged app:

```sh
scripts/check.sh
scripts/package.sh --local
open dist/LoadSide.app
```

The scripts forward the selected Xcode SDK to the compiler and linker, and verify each binary’s SDK metadata so supported macOS versions enable current native styling. The minimum supported macOS remains 14.

Local packaging builds universal binaries and maintains one ad-hoc signed app at `dist/LoadSide.app`, with `dist/loadside` linking to its bundled CLI. Repackaging replaces this local app only after the new app verifies. ZIPs and checksums are created only with `--archive`; those versioned archives are never overwritten. Run `scripts/clean.sh` to remove compiler caches and development scratch output while keeping the packaged app. Production packaging requires Developer ID signing and notarization; see [release instructions](docs/RELEASING.md).

## Use the app

1. Add the source `.ipa` in **Workspace** and select **Sign & export**. LoadSide inspects the app and lists its extensions.
2. Select a saved signing profile, or import the `.p12` and `.mobileprovision` files. Enter the P12 password; empty passwords are supported. Save the combination for reuse from **Signing Profiles**. Remembering the password is optional and uses macOS Keychain. Saved files load without a password prompt; the remembered password is requested when you start signing.
3. Review the signing plan. The default **Keep original** policy keeps the original bundle identifier in app metadata. When it differs from the profile, LoadSide uses one unambiguous exact profile identity in the signature and shows both IDs with a compatibility warning. **Automatic** can change the metadata ID to match the profile. An explicit override takes precedence and must match a supplied profile.
4. Review extension signing. **Reuse main profile (experimental)** is selected by default; **Require matching profiles** disables that fallback. The two checkboxes are mutually exclusive and always retain one selection. Matching extension profiles always take priority. You may also explicitly remove extensions and their features. **Strict** omits and logs unauthorized known Apple-approval entitlements and rejects other unsupported capabilities. Choose **Compatible** to allow other capability removals too.
5. Optionally add `.deb`, `.dylib`, or `.framework` inputs, choose a new export location, and sign. Review diagnostics if validation fails, correct the indicated input and retry.
6. Reveal the verified IPA in Finder or open **Local Library**, which receives a private copy automatically. Activity retains result metadata and diagnostics locally; it never saves passwords or private key material.

### Inject without signing files

Choose **Inject only**, add an IPA and one or more compatible injections, then **Inject & Export**. No P12, password, or provisioning profile is required. LoadSide validates the app and packages, injects supported payloads, removes stale signatures and embedded profiles, and exports an explicitly unsigned IPA. The original archives remain unchanged. The output must be signed before ordinary iOS installation and is not added to the signed-app library. Signature-only entitlements are removed with the old signatures; they cannot be recovered from the resulting unsigned app.

```sh
dist/loadside inject --ipa /path/App.ipa --inject /path/Tweak.deb --output /path/App-injected-unsigned.ipa
```

### Share the local app library

Open **Local Library** and choose **Start Sharing**. Copy the displayed link to a device on the same network. Keep LoadSide open and allow its local-network/firewall access if macOS requests it. The catalog supports browsing and IPA downloads over local HTTP. Sharing starts only when requested, uses a fresh access token each session, and stops when you stop sharing or quit the app. Anyone with that link can download its library; HTTP is unencrypted.

The library stores private copies under `~/Library/Application Support/LoadSide/Apps`. **Show Folder** reveals them; use the app to remove copies. The catalog never exposes a general directory listing or signing credentials. The library menu can add prior completed signing exports from Activity after checking their recorded SHA-256. Legacy exports without a recorded bundle version remain download-only.

For **Install** buttons, stop sharing, expand **Enable browser installation**, and enter the HTTPS origin of a reverse proxy pointing to this Mac's chosen port (default `8787`). Forward the complete token-prefixed path unchanged. Your iOS device must trust the HTTPS certificate and reach both the manifest and IPA at that address. LoadSide generates both; you supply the HTTPS proxy. A private LAN hostname and device-trusted certificate can keep traffic local. No tunnel or third-party manifest service is started automatically.

This follows [Apple's OTA distribution requirements](https://support.apple.com/guide/deployment/distribute-proprietary-in-house-apps-depce7cefc4d/web). [SignTools](https://github.com/SignTools/SignTools) and [SignTools-CI](https://github.com/SignTools/SignTools-CI) informed the service/catalog research; this implementation is independent and keeps signing on your Mac. An install link does not override provisioning, certificate trust, expiry, or device eligibility. On-device installation remains a release qualification requirement.

A certificate can sign different apps, but its provisioning profile still limits signing identities, entitlements and devices. Main-profile selection recognizes profiles for the app's actual nested bundles; ambiguous main profiles still require a clear selection. Automatic selection and explicit overrides require an authorized metadata bundle ID.

**Keep original compatibility** separates app metadata from the identity authorized for signing. For example, an app may retain `com.example.original` while its signed `application-identifier` uses the profile's prefix and `com.example.signing`. This is an independently implemented version of the supplied-profile approach in [SignTools](https://github.com/SignTools/SignTools) and its [SignTools-CI builder](https://github.com/SignTools/SignTools-CI/blob/8790863e64148768be9e8320c361411580d52554/sign.py#L948-L977). The app does not rewrite a mismatched wildcard into an invented identity. It shows and records a main-app mismatch; installation and app-service behavior remain unverified.

**Experimental extension compatibility**, enabled by default, also retains distinct child extension bundle IDs while signing unmatched extensions with the main profile's exact `application-identifier`. The selected main profile may differ from the preserved main bundle ID; an eligible extension must still be a child of that main bundle ID. Matching profiles always take priority; nested apps cannot use this fallback. Main or extension identity reuse can share keychain identity and break file importing, app groups or other features. Certificate, profile validity, platform, distribution and entitlement checks remain active. Signature verification does not establish device installation or working extensions. **Compatible entitlements** is a separate opt-in and never selected automatically.

## CLI

```sh
swift run loadside doctor
swift run loadside profile /path/App.mobileprovision
swift run loadside sign \
  --ipa /path/App.ipa \
  --p12 /path/Identity.p12 \
  --profile /path/App.mobileprovision \
  --profile /path/Extension.mobileprovision \
  --inject /path/CompatibleTweak.deb \
  --output /path/App-signed.ipa
```

The CLI prompts for the password without echoing it. For automation, use `--password-stdin` or `--password-file` with a file readable only by its owner. Never put passwords in command-line arguments. `--json` writes the result to stdout and progress JSONL to stderr. Ctrl-C cancels and cleans up. Run `loadside --help` for all options.

The CLI also defaults to preserving the original bundle identifier and experimental main-profile reuse for extensions. Use `--bundle-id-policy automatic` to allow profile-based identifier changes, or `--require-matching-extension-profiles` to disable experimental reuse. `--reuse-main-profile-for-extensions` remains available for explicit scripts; it cannot be combined with `--require-matching-extension-profiles` or `--remove-extensions`.

## Engineering

| Component | Responsibility |
| --- | --- |
| `LoadSideCore` | Validation, safe archives, Mach-O modification, injection, signing, verification, export |
| `LoadSideApp` | SwiftUI workspace, activity, diagnostics, recovery, local history |
| `LoadSideCLI` | Automation and environment/profile inspection |
| `CArchive` | Pinned libarchive headers; links to the macOS system library |

Read [architecture](docs/ARCHITECTURE.md), [security](SECURITY.md), [contributing](CONTRIBUTING.md), and [release qualification](docs/RELEASING.md). The repository intentionally excludes certificates, profiles, IPAs, and private keys.

MIT licensed. libarchive headers retain their BSD license in [third-party notices](THIRD_PARTY_NOTICES.md).
