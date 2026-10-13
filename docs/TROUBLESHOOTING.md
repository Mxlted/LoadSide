# Troubleshooting

Start with the specific diagnostic in **Activity** or the CLI's stderr. Correct the indicated input and retry with a new output path. Reports may contain paths, bundle identifiers, and certificate names; review and redact them before attaching to an issue. Never attach a P12, password, provisioning profile, or private IPA.

## Build and launch

- **Unsupported architecture:** use an Apple Silicon Mac and a native terminal/toolchain. Intel and Rosetta builds are intentionally rejected.
- **SDK or deployment metadata mismatch:** select the intended full Xcode installation, rebuild with `scripts/check.sh`, then package normally. `--skip-build` cannot repair stale binaries. `scripts/clean.sh` removes build caches while keeping `dist` and user inputs.
- **macOS cannot verify an evaluation app:** local builds are ad-hoc signed and unnotarized. Check the source and build locally or wait for a qualified release. Do not disable system-wide security controls.
- **Tests need a desktop session:** hosted SwiftUI tests require a macOS WindowServer session. The native password test can require an unlocked Keychain. See [Contributing](../CONTRIBUTING.md#tests-and-safety).

## Signing and injection

| Symptom | What to check |
| --- | --- |
| P12 import fails | Confirm the password and that the P12 includes the private key. An empty password is supported. Changing identity requires entering its password again. |
| Profile rejected | Use an unexpired Apple-signed profile containing the selected certificate and appropriate platform/distribution/device authorization. Offline checks cannot confirm current revocation. |
| App identifier mismatch | Review the signing plan. Keep original can retain metadata IDs using one exact profile identity, with unverified device behavior. Automatic or an explicit override changes metadata only to an authorized ID. |
| Missing extension profiles | Supply matching profiles, explicitly remove extensions, or evaluate the default experimental reuse policy with its documented limits. Companion apps still require their own matching profile. |
| Entitlement rejected | Strict is the default. Known unauthorized Apple-approval entitlements are omitted visibly in either policy. Compatible can remove other unsupported capabilities, which may break features. |
| Encrypted Mach-O | Obtain a legitimately decrypted input. LoadSide does not decrypt apps. |
| Insufficient header space or unsupported dependency | Rebuild the injection with suitable header padding/dependencies if you control its source. Arbitrary jailbreak tweaks are not guaranteed to work on stock iOS. |
| Archive/path/size validation fails | Recreate the archive from trusted source material. Do not bypass limits or rename suspicious paths merely to suppress the diagnostic. |
| Output already exists | Choose a new filename. LoadSide never overwrites an existing export. |

See [signing policies](GETTING_STARTED.md#understand-the-signing-policies), [compatibility](COMPATIBILITY.md), and the [Apple-approval entitlement catalog](APPROVAL_ENTITLEMENTS.md).

## Sharing and installation

- **Automatic HTTPS unavailable on macOS 14:** use Local downloads only or My HTTPS server. The pinned official helper requires macOS 15.
- **Helper download or tunnel fails:** check internet access to GitHub and Cloudflare. Setup cancellation, failure, or helper exit closes sharing. Quick Tunnels have no uptime guarantee.
- **Local catalog unreachable:** keep LoadSide open, check the Mac's firewall/local-network permission, and use the same network for local HTTP. Restarting sharing creates a new private link; old links expire.
- **Custom HTTPS fails:** the device must trust the HTTPS certificate, and the reverse proxy must forward the complete token-prefixed path unchanged to the chosen local port.
- **No install button:** local-only sharing and legacy exports without a recorded bundle version are download-only. HTTPS must be ready for OTA links.
- **iOS rejects installation or an extension fails:** signature verification is not device qualification. Check certificate trust, expiry, profile/device eligibility, and entitlement/identifier compatibility. Installation and runtime behavior remain release blockers until tested with authorized devices.

[Sharing guide](SHARING.md) explains the privacy and availability differences between modes.

## Get help or report a defect

Search [existing issues](https://github.com/Mxlted/LoadSide/issues) and include the LoadSide version, macOS version, native Apple Silicon toolchain, steps, expected behavior, and sanitized diagnostic code. For exploitable vulnerabilities use [private security reporting](https://github.com/Mxlted/LoadSide/security/advisories/new), as described in [Security](../SECURITY.md).
