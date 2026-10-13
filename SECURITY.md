# Security

LoadSide handles private signing identities and untrusted archives. Keep signing material on a trusted Mac. Signing and injection run locally; P12s, profiles, and passwords are never sent to a service. Apple's local trust evaluation may use cached system trust information; LoadSide disables profile trust network fetching and does not promise current revocation checks.

Sharing is explicit and separate from signing. **Local downloads only** serves managed IPA copies over unencrypted local HTTP. **Automatic HTTPS** downloads a pinned helper from GitHub and forwards the shared catalog, manifests, and IPA downloads through Cloudflare. **My HTTPS server** uses the configured reverse proxy. Anyone holding the current private sharing URL can download the library; stop sharing to invalidate it. See [sharing limitations](docs/COMPATIBILITY.md#local-sharing-and-installation).

## Boundaries

- Source files are read and staged; they are not modified in place.
- Per-job temporary keychains isolate imported private keys from the login keychain.
- Passwords are never persisted in history, diagnostic reports or profile metadata, and never supplied as subprocess arguments. Explicitly remembered passwords use macOS Keychain generic-password items; signing identities still use disposable per-job keychains.
- Saved signing profiles copy imported P12 and provisioning files into private local storage. Preserve strong P12 passwords: file permissions do not add cryptographic protection to an unprotected P12.
- IPA/DEB extraction validates paths, symbolic links, entry types, duplicates, and resource limits. DEB maintainer scripts and payload executables are never run.
- Mach-O changes require supported formats and verified header capacity.
- Profiles authorize each bundle's certificate, identity, and entitlements. Offline verification is not an installation guarantee.
- Final output paths are not overwritten. A failed or cancelled job must not expose a partial final IPA.

History and diagnostics contain file paths, bundle identifiers, certificate display names, and error messages. They are operational metadata, not anonymous telemetry. Review exported reports before sharing. Use Activity's clear-history control to remove retained records.

Cleanup covers normal completion, errors, and cancellation. A forced process kill or power loss may interrupt cleanup. If that happens, close LoadSide and review stale `LoadSide-*` temporary directories/keychains before deleting them; never remove an unrelated or active keychain. Memory held in Swift strings cannot be guaranteed to be wiped.

## Reporting

Do not file a public issue containing an exploitable vulnerability, private key, profile, or proprietary IPA. Use [GitHub private vulnerability reporting](https://github.com/Mxlted/LoadSide/security/advisories/new) to contact the maintainer. Include the affected version, minimal sanitized reproduction, and impact. Do not include customer credentials.

Public-release qualification and known gaps are tracked in [release instructions](docs/RELEASING.md) and [status](docs/STATUS.md).
