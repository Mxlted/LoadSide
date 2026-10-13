# Installation

LoadSide targets **macOS 14 or later on Apple Silicon**. Intel Macs and Rosetta sessions are unsupported. Automatic HTTPS sharing needs macOS 15 or later; signing, injection, and local/custom HTTPS sharing retain the macOS 14 target. Minimum-version runtime qualification remains outstanding.

## Release availability

**0.1.0-rc.3 is a local evaluation candidate. No production download has been published.** Follow [GitHub Releases](https://github.com/Mxlted/LoadSide/releases) for qualified downloads and read the [current status](STATUS.md) before evaluating a build.

A future qualified release will contain `LoadSide-<version>-macOS-arm64.zip` and a matching `.sha256` checksum. Download both from the same release, verify the checksum with `shasum -a 256 -c <archive>.sha256`, unzip, and move `LoadSide.app` into Applications. The CLI is bundled at `LoadSide.app/Contents/Helpers/loadside`. Production downloads must be Developer ID signed and notarized; local archives have `-local` in their name and are not equivalent.

## Build a local evaluation copy

Install Xcode with Swift 6 or newer, select it as the active developer toolchain, and accept its license. A full native ARM64 toolchain is required. From a checkout:

```sh
git clone https://github.com/Mxlted/LoadSide.git
cd LoadSide
scripts/check.sh
scripts/package.sh --local
open dist/LoadSide.app
```

The scripts select the active macOS SDK and verify ARM64 architecture, the macOS 14 deployment target, and SDK metadata for every packaged executable. The result is ad-hoc signed. If macOS quarantines an evaluation archive, use the system's per-app approval controls only after reviewing its origin; do not disable Gatekeeper globally.

`dist/loadside` points to the CLI inside the current app. Packaging replaces the local app only after verification. To explicitly create a non-overwriting evaluation ZIP and checksum, use `scripts/package.sh --local --archive`. See [release engineering](RELEASING.md) for production packaging and provenance.

The packaged app uses Apple's system tools. Signing does not require Python, Node, Homebrew, or a hosted service. Automatic HTTPS separately downloads an optional verified helper on first use.

## Before your first export

You need a decrypted IPA you are authorized to modify, an Apple-issued identity and private key in a `.p12`, its password (which may be empty), and valid `.mobileprovision` files for the app and any retained extensions. The profiles must authorize the selected certificate, entitlements, and intended device/distribution method.

For **Inject only**, the IPA and compatible injection files are sufficient. Its unsigned output requires later signing before ordinary iOS installation.

Continue with [getting started](GETTING_STARTED.md). Build problems and signing failures are covered in [troubleshooting](TROUBLESHOOTING.md).
