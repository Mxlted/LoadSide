# Installation

LoadSide targets **macOS 14 or later on Apple Silicon**. Intel Macs and Rosetta sessions are unsupported. Automatic HTTPS sharing needs macOS 15 or later; signing, injection, and local/custom HTTPS sharing retain the macOS 14 target. Minimum-version runtime qualification remains outstanding.

## Download and install

Get **0.1.0-rc.3** from [GitHub Releases](https://github.com/Mxlted/LoadSide/releases/tag/v0.1.0-rc.3). This experimental prerelease is **ad-hoc signed and not notarized**. Device installation/runtime and full macOS 14 qualification remain incomplete; see [verification status](STATUS.md).

1. Download `LoadSide-0.1.0-rc.3-macOS-arm64-local.dmg`.
2. Open the DMG and drag **LoadSide** onto **Applications**.
3. Eject the disk image and open **LoadSide** from Applications.

The ZIP contains the same app: unzip it and move `LoadSide.app` into Applications. Choose the DMG or ZIP asset, not GitHub's automatically generated source-code archives. The `-local` label identifies an ad-hoc build; it does not mean you need to compile it.

### First launch

macOS may block this prerelease because it has not been notarized. After checking that you downloaded it from this repository, try opening it, then use **System Settings > Privacy & Security > Open Anyway** if you choose to proceed. This grants an exception for this app. See [Apple's instructions](https://support.apple.com/en-us/102445); do not disable Gatekeeper globally. If macOS reports malware or damaged content, stop and verify the download instead of bypassing that warning.

### Verify a download

Download the matching `.sha256` asset into the same folder. In Terminal, change to that folder and run:

```sh
shasum -a 256 -c LoadSide-0.1.0-rc.3-macOS-arm64-local.dmg.sha256
```

The result should say `OK`. For the ZIP, use its `.zip.sha256` file instead. The CLI is bundled at `/Applications/LoadSide.app/Contents/Helpers/loadside`; run it with `--help` or follow the [CLI guide](CLI.md).

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

`dist/loadside` points to the CLI inside the current app. Packaging replaces the local app only after verification. Use `scripts/package.sh --local --dmg` for a disk image, `--archive` for a ZIP, or `--archive --dmg` for both. Each includes a checksum and refuses to overwrite existing artifacts. See [release engineering](RELEASING.md) for production packaging and provenance.

The packaged app uses Apple's system tools. Signing does not require Python, Node, Homebrew, or a hosted service. Automatic HTTPS separately downloads an optional verified helper on first use.

## Before your first export

You need a decrypted IPA you are authorized to modify, an Apple-issued identity and private key in a `.p12`, its password (which may be empty), and valid `.mobileprovision` files for the app and any retained extensions. The profiles must authorize the selected certificate, entitlements, and intended device/distribution method.

For **Inject only**, the IPA and compatible injection files are sufficient. Its unsigned output requires later signing before ordinary iOS installation.

Continue with [getting started](GETTING_STARTED.md). Build problems and signing failures are covered in [troubleshooting](TROUBLESHOOTING.md).
