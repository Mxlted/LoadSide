# Delivery status

Target: **0.1.0-rc.2**, local evaluation release candidate. This file records evidence, not aspirational completion.

| Area | State | Evidence / remaining work |
| --- | --- | --- |
| Architecture | Implemented | Native macOS 14+ SwiftUI, shared Swift 6 engine and CLI, system libarchive |
| Safe IPA/DEB handling | Verified locally | Adversarial archive tests, thin/fat Mach-O editing, real DEB injection and signing |
| Certificate/profile validation | Verified locally | Apple-signed profile validation, actual P12 import, certificate matching, isolated-keychain native integration tests |
| Signing and entitlement policy | Verified locally | Actual supplied IPA signed with matching credentials; strict rejects unsupported capabilities, compatible records omissions |
| Desktop workflows | Implemented / visually reviewed | Redesigned native workspace, visible app-ID plan, saved identity selection, extension warnings, DEB picker and reset defaults checked through the UI |
| Saved signing profiles | Verified locally | Actual supplied identity saved, private copies reused after temporary import sources were deleted, rename/delete/reload and native Keychain CRUD verified |
| Automatic app-ID resolution | Verified locally | Explicit profile mismatch resolved without a manual override; ambiguity, wildcard, Preserve and certificate membership tested |
| Automated tests | Passing | 64 tests, zero failures or skips; unit, adversarial and native-tool integration |
| Build and release automation | Local package verified / CI configured | Universal app and ZIP built, nested signatures and checksum verified; Apple silicon/Intel GitHub workflows have not run |
| Device installation and launch | Unverified | Exported IPA has not been installed or exercised on a registered iOS device |
| Developer ID / notarization | Credentials needed | No macOS distribution identity or notary credentials supplied; local artifacts are ad-hoc signed |
| GitHub publication | Not configured | No repository remote provided; source history and release artifacts remain local |

## RC.2 qualification — 2026-10-12

- The supplied diagnostic describes a real app-ID authorization mismatch. The supplied Apple-signed profile authorizes one exact app ID, not arbitrary identifiers. Automatic mode now selects that unambiguous ID after checking certificate membership; Preserve mode reports the precise mismatch and recovery options.
- The actual Cercube 6.4.1 DEB and decrypted YouTube 21.41.5 IPA in the private `deb_test` folder completed signing without a manual app-ID override. The output contains three signed code objects, `Cercube.dylib`, and an app-root `Cercube.bundle`.
- Independent re-extraction verified all three signatures with deep strict verification, the embedded provisioning profile, the rewritten app ID, the injected load command, and all 24 original resource files byte for byte. SHA-256 checks confirmed every supplied input remained unchanged.
- This export explicitly removed six unmatched extensions and used Compatible entitlements, omitting eight unsupported capabilities. These choices have visible warnings and recorded diagnostics; no profile restrictions are bypassed.
- Saved-profile qualification used the actual supplied P12 and Apple CMS profile. A temporary import source was removed after saving, the store was reconstructed, and the private copies remained usable. Permissions, rename, delete, integrity, expiry, corruption recovery and opt-in native Keychain operations passed. No plaintext password is written to profile metadata.
- The user's files were saved as “Personal Ad Hoc” without remembering its password. The app automatically restored the selection after restart. The Signing Profiles manager, file pickers, app-ID plan, Preserve mismatch, extension removal, Compatible policy and New Session defaults were inspected through the native interface.
- The automated suite passed 64 tests, with no failures or skips. Newly covered behavior includes exact/wildcard ID resolution, nested DEB resources, hidden-code/collision rejection, persistent profile integrity, real Keychain CRUD and private-keychain cleanup.
- Optimized universal GUI and CLI builds passed; both ARM64 and x86_64 slices target macOS 14.0. Release CLI version/environment/error-path smoke checks and shell syntax checks passed. Execution on Intel and macOS 14 remains unverified.
- Local signing establishes signature/export integrity. Cercube's behavior on this YouTube version, its resource lookup at runtime, installation and launch still require an eligible iOS device.

## RC.1 baseline qualification — 2026-10-12

Host: Apple silicon, macOS 27.0.1 (26A434), Apple Swift 6.4. Tests use Apple's actual `codesign`, Security/keychain APIs, the iOS SDK and the system archive library, rather than mocked success responses.

- The supplied approximately 142 MB decrypted IPA was signed using the supplied Apple-issued P12 and provisioning profile. The successful export contained 13 signed code objects.
- A second export injected a locally built, benign ARM64 no-op library from a real Debian package. All 14 code objects, including the injected library, passed local signature verification.
- Both exported IPAs were independently unpacked again and passed `codesign --verify --deep --strict`. Embedded profile bytes, signed app identity, capability omissions, extension removal and the injected load command were checked. SHA-256 checks confirmed the original IPA, P12 and profile were unchanged.
- The profile authorizes a different app identifier and lacks the original Safari extension's profile. Both successful jobs explicitly changed the app identifier and enabled extension removal in the staged copy.
- Strict entitlement mode correctly rejected an unauthorized associated-domains claim. Compatible mode explicitly removed eight unsupported capabilities: associated domains, alternate video decoder selection, declared age range, user-assigned device name, group sessions, multicast, StoreKit request data, and application groups. Runtime features depending on these claims require device qualification.
- Private input files, passwords, output IPAs and detailed qualification logs are excluded from Git. Neither the real app nor the signing identity is distributed with LoadSide.
- The release GUI and CLI built successfully as universal ARM64 + x86_64 binaries. Both slices declare macOS 14.0 as their minimum. This host exercised the ARM64 build; execution on Intel and macOS 14 remains part of external qualification.
- The packaged app launched successfully. Extension removal remains visibly flagged when options are collapsed, and New Session restores strict entitlements and preserves extensions by default. Release CLI smoke checks passed. See the [RC.1 artifact qualification record](QUALIFICATION-0.1.0-rc.1.md) for provenance and checksums.

Synthetic tests additionally cover nested app/extension signing, ZIP round-trip verification and tamper detection, temporary-keychain cleanup, unsupported profile signatures, malformed archives and binaries, dependency resolution, cancellation, subprocess limits and exclusive atomic export.

Local signature verification establishes export integrity; it does not establish device eligibility, certificate revocation status, application behavior or tweak runtime compatibility. See `RELEASING.md` for the remaining release gate.
