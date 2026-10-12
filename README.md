# LoadSide

A native macOS workspace for signing decrypted iOS apps with your own **P12 certificate and provisioning profiles**. Select an IPA, add signing material, optionally inject compatible libraries, and export a verified IPA. Everything runs on your Mac.

**Status: 0.1.0-rc.2 — release candidate for local evaluation.** The repository contains a real signing engine, desktop app, CLI, tests, and release tooling. A local build is not a notarized public release. See [delivery status](docs/STATUS.md) for verification evidence and outstanding qualification.

## What it does

- Imports PKCS#12 signing identities into an isolated, temporary keychain.
- Checks certificate validity, signed provisioning profiles, bundle identifiers, and profile authorization for each app and extension.
- Resolves a unique profile-authorized app identifier automatically and previews identifier and extension compatibility before signing.
- Saves reusable signing profiles with private local copies of P12/provisioning files and optional password storage in macOS Keychain.
- Reconciles entitlements with a strict default; an explicit compatible mode can drop unsupported claims with diagnostics.
- Keeps app extensions by default; an explicit option can omit them when you only have a main-app profile.
- Extracts IPA and DEB archives with path, link, file type, and expansion limits.
- Injects supported relocatable dylibs and frameworks, updates Mach-O load commands and dependencies, and rejects unsafe or incompatible changes.
- Signs code from the inside out, verifies signatures, and atomically publishes an IPA without overwriting existing files.
- Shows real progress, cancellation, actionable errors, export history, and diagnostic reports.
- Provides the same engine through a CLI for repeatable automation.

## Requirements

- macOS 14 or later, Apple silicon or Intel.
- A decrypted IPA that you are authorized to modify.
- An Apple-issued code-signing identity with its private key in a `.p12` file and its password.
- A current provisioning profile for each retained app identifier, including nested extensions or companion apps. The profile must include the selected certificate and permit the target device/distribution method. Extensions explicitly removed from the export do not need profiles.
- Xcode with Swift 6 or newer to build from source. The packaged app uses Apple's system tools and does not need Python, Node, Homebrew, or a network service.

LoadSide does not decrypt FairPlay apps, create certificates or profiles, bypass device provisioning, install apps to devices, or make arbitrary jailbreak tweaks compatible with stock iOS. Offline validation cannot establish current revocation status. See [compatibility](docs/COMPATIBILITY.md).

## Build and run

Open `Package.swift` in Xcode and run the **LoadSideApp** executable, or use:

```sh
swift run LoadSideApp
```

Build and verify the project:

```sh
scripts/check.sh
scripts/package.sh --local
open "dist/LoadSide-$(cat VERSION)-local/LoadSide.app"
```

Local packaging builds universal binaries and produces an ad-hoc signed `.app`, ZIP, and SHA-256 checksum in `dist/`. The unpacked app is version-specific: `dist/LoadSide-0.1.0-rc.2-local/LoadSide.app`. Packaging refuses to overwrite existing artifacts. It is intended for local testing. Production packaging requires Developer ID signing and notarization; see [release instructions](docs/RELEASING.md).

## Use the app

1. Add the source `.ipa` in **Sign**. LoadSide inspects the app and lists its extensions.
2. Select a saved signing profile, or import the `.p12` and `.mobileprovision` files. Enter the P12 password; empty passwords are supported. Save the combination for reuse from **Signing Profiles**. Remembering the password is optional and uses macOS Keychain.
3. Review the signing plan. **Automatic** preserves the original identifier if authorized; otherwise it uses a single unambiguous explicit identifier from the matching profile. You can choose **Preserve** or enter an override.
4. If extensions lack matching profiles, add their profiles or explicitly remove the extensions and their features. Leave entitlement handling on **Strict** unless you intentionally accept capability removal.
5. Optionally add `.deb`, `.dylib`, or `.framework` inputs, choose a new export location, and sign. Review diagnostics if validation fails, correct the indicated input and retry.
6. Reveal the verified IPA in Finder. Activity retains result metadata and diagnostics locally; it never saves passwords or private key material.

A certificate can sign different apps, but its provisioning profile still limits app identifiers, entitlements and devices. An explicit profile cannot preserve arbitrary app identifiers. Reusing its identifier for multiple exports means those apps occupy the same installation identity on a device. LoadSide reports identifier changes and never bypasses profile authorization.

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

## Engineering

| Component | Responsibility |
| --- | --- |
| `LoadSideCore` | Validation, safe archives, Mach-O modification, injection, signing, verification, export |
| `LoadSideApp` | SwiftUI workspace, activity, diagnostics, recovery, local history |
| `LoadSideCLI` | Automation and environment/profile inspection |
| `CArchive` | Pinned libarchive headers; links to the macOS system library |

Read [architecture](docs/ARCHITECTURE.md), [security](SECURITY.md), [contributing](CONTRIBUTING.md), and [release qualification](docs/RELEASING.md). The repository intentionally excludes certificates, profiles, IPAs, and private keys.

MIT licensed. libarchive headers retain their BSD license in [third-party notices](THIRD_PARTY_NOTICES.md).
