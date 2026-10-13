# Contributing

Read [engineering invariants](AGENTS.md) and [architecture](docs/ARCHITECTURE.md) before changing the signing pipeline. An Apple Silicon Mac running macOS 14+ and Xcode with Swift 6+ are required. Run the toolchain natively; Intel Macs and Rosetta sessions are unsupported. Open `Package.swift` in Xcode; there is no generated Xcode project to maintain and no third-party Swift package to install.

## Development loop

From the repository root:

```sh
swift build
swift test --filter EntitlementTests
scripts/format.sh --check
scripts/check.sh
scripts/package.sh --local
open dist/LoadSide.app
```

Use `swift test --filter <TestClass>` for the area being changed, then run `scripts/check.sh` before submitting. The full check runs formatting, shell syntax, packaging guards, all test targets, an optimized build, SDK metadata verification, CLI smoke checks, and tracked-file hygiene. Swift warnings and C deprecations are errors; the documented legacy Keychain waiver is confined to `CFileKeychain.c`. `--skip-build` skips **both tests and compilation** and requires existing release binaries; it is only for repeating smoke checks after a verified build.

Interactive agent workflows use `xcodebuildmcp swift-package build` and `test` when available; inspect their `--help` first and pass this checkout as `--package-path`. Repository scripts use Swift directly so CI does not need XcodeBuildMCP. Do not run competing builds against the same build directory.

Build, verification, and packaging scripts share one ARM64 configuration (including warning policy, so packaging can reuse the verified release build) and reject unsupported hosts before compiling. The package manifest also rejects unsupported hosts, and the core target rejects non-ARM64 compilation. This host constraint must never be used to restrict the architectures parsed inside user archives.

The release scripts deliberately forward the selected macOS SDK to both compilation and linking. Use those scripts to create distributable bundles; a plain development build does not replace their exact-architecture, macOS 14 deployment-target, SDK, and signature checks. `scripts/package.sh --local` updates `dist/LoadSide.app` and `dist/loadside` after verification. `scripts/clean.sh --dry-run` previews generated-file cleanup and preserves `dist` by default. Never put user archives or signing material in build directories.

## Finding the right code

| Change | Start here |
| --- | --- |
| Signing stages and progress | `SigningEngine`, `SigningRequest`, `SigningEvent` |
| Bundle discovery and metadata | `BundleInventory`, `SigningPreflight` |
| Archive safety and final output commit | `Archive`, `IPAExport` |
| Injection and unsigned exports | `Injection`, `InjectionEngine`, `MachO` |
| Profile authorization and identity | `ProvisioningProfile`, `EntitlementResolver`, `ExtensionSigning` |
| Saved credentials and private keychains | `SavedSigningProfileStore`, `SigningIdentity`, `CFileKeychain` |
| Shared library and browser downloads | `LocalAppLibrary`, `LocalAppServer`, `LocalHTTP` |
| HTTPS helper lifecycle | `CloudflaredInstaller`, `LocalAppTunnel` |
| Desktop state and persistence | `WorkspaceModel`, `LocalLibraryModel`, `JobRecord`, `JobHistoryStore` |
| Signing controls and disclosure state | `WorkspaceView`, `SigningOptionsView`, `FullRowDisclosureStyle` |
| CLI parsing and execution | `LoadSideCLI` and its adjacent support files |

Keep policy and filesystem safety in `LoadSideCore`; clients translate input and display real engine events. Keep a coordinating model together when its state changes together. Extract independent responsibilities, not one file per method.

## Style and review

`scripts/format.sh` applies the [Swift toolchain formatter](https://github.com/swiftlang/swift-format) using `.swift-format`; `--check` fails on differences. Four-space indentation, a 140-column wrapping target, ordered imports, and one statement per line make the binary and policy code easier to audit. Long literal diagnostics and HTML are left intact. `.editorconfig` supplies editor defaults. Do not reformat the vendored CArchive headers. Use the same selected Swift toolchain for formatting and checks; formatter output can change with toolchain upgrades.

Prefer descriptive domain names, early validation, and small helpers with explicit inputs. Comments should explain security assumptions, lifecycle ownership, or compatibility decisions. Preserve public APIs, persisted Codable keys, diagnostic codes, and CLI output contracts unless the change intentionally revises them. Keep formatting-only changes separate from behavioral changes when practical.

## Tests and safety

Keep changes focused and add meaningful tests for parsing, policy, cleanup, or export behavior. Unit tests must not require real credentials, internet access, or the login keychain. Local server tests use loopback sockets and synthetic IPA bytes. Native-tool integration tests use generated fixtures in temporary directories, but must not weaken production trust checks. One native password-storage integration test creates and removes a uniquely namespaced generic-password item in the default macOS Keychain; it may require an unlocked Keychain. Signing identity tests use disposable keychains. Synthetic success never establishes iOS installation support.

`LoadSideCoreTests/Support` contains shared binary, archive, profile, and library fixtures. Put reusable fixture builders there rather than hiding them in an unrelated test case. Keep scenario-specific helpers next to their tests. `LoadSideAppTests` covers history compatibility, persistence, and hosted desktop controls; `LoadSideCLITests` covers argument and credential-input boundaries without signing a user archive.

Run `swift test --filter 'WorkspaceAccessibilityTests|WorkspaceModelTests'` for desktop regressions. Interaction tests host the real SwiftUI views in a native window, enable SwiftUI's documented accessibility environment, and invoke public AppKit accessibility actions. They require a macOS WindowServer session but no cross-process Accessibility permission. The in-process bridge omits some virtual controls inside scroll views, so signing options are also hosted directly as the same production component. Test models receive private temporary stores and in-memory passwords; initialization and profile-inspection tasks are awaited before cleanup. Controlled profile-inspection fixtures exercise retries, removal, and reselection without real credentials; always release suspended fixture work during teardown, including on test failure. Use stable accessibility identifiers for controls and bounded waits for rendered state.

Keep segmented-picker actions, file dialogs, system Keychain prompts, application menu shortcuts, and full process launch/quit checks in the manual qualification workflow. Hosted segmented-picker actions currently produce a SwiftUI view-update warning, so tests check their disabled state and both workflows' rendered readiness without driving those actions. Hosted interactions do not replace VoiceOver and pointer testing or establish complete scroll-container behavior.

For archive and binary changes, include malformed-input and traversal coverage. For entitlement changes, include explicit/wildcard profiles, type mismatches, team/app-prefix differences, extension cases, and strict/compatible outcomes. For process changes, cover cancellation, timeout, bounded output, and cleanup. Test the failure boundary, including unchanged source bytes, no partial final export, and temporary-work cleanup.

Pull requests should explain the behavior change, evidence from tests, and remaining device qualification. Never claim installation support based solely on a synthetic signature. Update the changelog and compatibility documentation when the supported surface changes.
