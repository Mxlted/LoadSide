# Delivery status

Target: **0.1.0-rc.1**, local evaluation release candidate. This file records evidence, not aspirational completion.

| Area | State | Evidence / remaining work |
| --- | --- | --- |
| Architecture | Implemented | Native macOS 14+ SwiftUI, shared Swift 6 engine and CLI, system libarchive |
| Safe IPA/DEB handling | Verified locally | Adversarial archive tests, thin/fat Mach-O editing, real DEB injection and signing |
| Certificate/profile validation | Verified locally | Apple-signed profile validation, actual P12 import, certificate matching, isolated-keychain native integration tests |
| Signing and entitlement policy | Verified locally | Actual supplied IPA signed with matching credentials; strict rejects unsupported capabilities, compatible records omissions |
| Desktop workflows | Implemented / visually reviewed | File selection, trusted profile inspection, injection, progress, cancellation, diagnostics, history and explicit extension removal |
| Automated tests | Passing | 44 tests, zero failures or skips; unit, adversarial and native-tool integration |
| Build and release automation | Configured | Apple silicon/Intel CI, universal local packaging, protected signed release workflow; GitHub execution has not run |
| Device installation and launch | Unverified | Exported IPA has not been installed or exercised on a registered iOS device |
| Developer ID / notarization | Credentials needed | No macOS distribution identity or notary credentials supplied; local artifacts are ad-hoc signed |
| GitHub publication | Not configured | No repository remote provided; source history and release artifacts remain local |

## Local qualification — 2026-10-12

Host: Apple silicon, macOS 27.0.1 (26A434), Apple Swift 6.4. Tests use Apple's actual `codesign`, Security/keychain APIs, the iOS SDK and the system archive library, rather than mocked success responses.

- The supplied approximately 142 MB decrypted IPA was signed using the supplied Apple-issued P12 and provisioning profile. The successful export contained 13 signed code objects.
- A second export injected a locally built, benign ARM64 no-op library from a real Debian package. All 14 code objects, including the injected library, passed local signature verification.
- Both exported IPAs were independently unpacked again and passed `codesign --verify --deep --strict`. Embedded profile bytes, signed app identity, capability omissions, extension removal and the injected load command were checked. SHA-256 checks confirmed the original IPA, P12 and profile were unchanged.
- The profile authorizes a different app identifier and lacks the original Safari extension's profile. Both successful jobs explicitly changed the app identifier and enabled extension removal in the staged copy.
- Strict entitlement mode correctly rejected an unauthorized associated-domains claim. Compatible mode explicitly removed eight unsupported capabilities: associated domains, alternate video decoder selection, declared age range, user-assigned device name, group sessions, multicast, StoreKit request data, and application groups. Runtime features depending on these claims require device qualification.
- Private input files, passwords, output IPAs and detailed qualification logs are excluded from Git. Neither the real app nor the signing identity is distributed with LoadSide.
- The release GUI and CLI built successfully as universal ARM64 + x86_64 binaries. Both slices declare macOS 14.0 as their minimum. This host exercised the ARM64 build; execution on Intel and macOS 14 remains part of external qualification.

Synthetic tests additionally cover nested app/extension signing, ZIP round-trip verification and tamper detection, temporary-keychain cleanup, unsupported profile signatures, malformed archives and binaries, dependency resolution, cancellation, subprocess limits and exclusive atomic export.

Local signature verification establishes export integrity; it does not establish device eligibility, certificate revocation status, application behavior or tweak runtime compatibility. See `RELEASING.md` for the remaining release gate.
