# LoadSide

A native macOS workspace for signing decrypted iOS apps with your own **P12 certificate and provisioning profiles**. Select an IPA, add signing material, optionally inject compatible libraries, and export a verified IPA. Everything runs on your Mac.

**Status: 0.1.0-rc.1 — release candidate for local evaluation.** The repository contains a real signing engine, desktop app, CLI, tests, and release tooling. A local build is not a notarized public release. See [delivery status](docs/STATUS.md) for verification evidence and outstanding qualification.

## What it does

- Imports PKCS#12 signing identities into an isolated, temporary keychain.
- Checks certificate validity, signed provisioning profiles, bundle identifiers, and profile authorization for each app and extension.
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

Local packaging builds universal binaries and produces an ad-hoc signed `.app`, ZIP, and SHA-256 checksum in `dist/`. The unpacked app is version-specific: `dist/LoadSide-0.1.0-rc.1-local/LoadSide.app`. Packaging refuses to overwrite existing artifacts. It is intended for local testing. Production packaging requires Developer ID signing and notarization; see [release instructions](docs/RELEASING.md).

## Use the app

1. Add the source `.ipa` in Workspace.
2. Select the `.p12`, enter its password, and add `.mobileprovision` files. Empty passwords are supported for unprotected identities.
3. Optionally add `.deb`, `.dylib`, or `.framework` inputs and review the compatibility guidance.
4. Set an optional app name or bundle identifier. Leave entitlement handling on **Strict** unless you intentionally accept capability removal. If you only have a main-app profile, you can explicitly remove app extensions; their features will be unavailable.
5. Choose a new export location and start signing. Review the event log if validation fails; fix the indicated input and retry.
6. Reveal the verified IPA in Finder. Activity retains result metadata and diagnostics locally; it never saves passwords or private keys.

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
