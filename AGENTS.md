# LoadSide engineering instructions

LoadSide is a native macOS application and CLI for locally signing decrypted iOS IPA archives with a PKCS#12 identity and provisioning profiles. Treat user archives, packages, profiles, paths, and tool output as untrusted input.

## Architecture

- `LoadSideCore` owns validation, isolated workspaces, archive safety, Mach-O editing, injection, entitlements, signing, and export. It must not depend on SwiftUI.
- `LoadSideApp` is the macOS SwiftUI client. It presents real engine events; never simulate progress or successful output.
- `LoadSideCLI` is an automation client of the same engine. Keep passwords out of command-line arguments and stored job records.
- `CArchive` is a system module for Apple's libarchive. Avoid adding remote dependencies without a concrete need.
- `CFileKeychain` contains the required legacy file-keychain lifecycle and trusted-application ACL calls. Keep its compatibility waiver local to that implementation; never substitute a shared identity destination or widen its fixed access policies to silence warnings.

## Required invariants

1. Never modify source IPAs, P12 files, profiles, or DEBs. Stage work in a private per-job directory and clean it on success, failure, and cancellation.
2. Never import user identities into the login keychain. Use a dedicated temporary keychain and remove it after use.
3. Never log passwords, private key bytes, or environment values. Do not commit signing material or customer archives.
   Saved signing profiles may retain explicitly imported credential files in private Application Support storage. Remembered passwords require explicit opt-in and macOS Keychain; never store them in metadata or history. Profile removal must remove its remembered password and managed copies without touching originals.
4. Validate every extracted path, link, file type, and size. Never execute DEB maintainer scripts or extracted binaries.
5. Never claim to decrypt an IPA. Reject encrypted Mach-O code. Reject unsupported patching when safe header space is absent.
6. Sign nested code explicitly from the inside out, with per-bundle entitlements and profiles. Do not use `codesign --deep` to sign.
7. Strict entitlement reconciliation is the default. Known entitlements requiring Apple approval are omitted with visible diagnostics when not authorized by the selected profile, in either policy; authorized claims are preserved. Keep the explicit classification documented and never infer it from missing authorization or key prefixes. Other capability removal requires the explicit compatible policy and visible diagnostics.
   Preserve the app's original metadata bundle identifier by default. When no matching main profile exists, Keep original may use one unambiguous exact main-profile identity in signed entitlements without changing that metadata ID; report the mismatch and unverified device behavior. Explicit Automatic resolution and manual overrides must use a profile-authorized metadata identifier and report any change. Experimental extension identity reuse is the default, with matching profiles always preferred. The two extension signing policies use mutually exclusive checkboxes; one must remain selected. Reuse may retain a child extension's bundle ID while using the main profile's exact signing application-identifier; always report this mismatch and unverified device behavior. It never bypasses certificate membership, profile validity, entitlement authorization, platform/distribution checks, or device restrictions. Nested apps cannot use this fallback.
8. Verify before exporting. Do not overwrite an existing output. Cancellation and failures must not leave a partial final IPA.
9. Never describe a local ad-hoc build as Developer ID signed, notarized, or device-qualified. Record exactly what was verified.

## Development and verification

Target Apple Silicon (ARM64) only, macOS 14+, Swift 6, and Foundation/Security/libarchive. Build and run the toolchain natively; reject Intel and Rosetta hosts early. Keep host architecture restrictions separate from thin/universal Mach-O handling inside user archives. Preserve macOS availability checks and the file-Keychain compatibility boundary. Use `xcodebuildmcp` for interactive build and test orchestration when available; repository CI/release scripts use the standard Swift toolchain directly. Check workflow `--help` before using the CLI. Run relevant unit tests and a full build after interface changes. Test hostile archives, malformed binaries, policy boundaries, cancellation, and failure cleanup, not just happy paths. Keep `docs/STATUS.md`, `CHANGELOG.md`, and support limitations accurate.

Use `scripts/format.sh` and `.swift-format` for owned Swift sources; `scripts/check.sh` enforces formatting. Preserve vendored CArchive header formatting. Keep shared test fixtures in `Tests/LoadSideCoreTests/Support`, and retain persisted Codable keys, public APIs, and diagnostic codes during refactors. See `CONTRIBUTING.md` for the source map and validation workflow.

Synthetic credential tests must verify import, private-key operation, isolation, and cleanup without changing system trust or keychain search lists. They cannot establish external `codesign` trust; qualify that with a real authorized identity.

Use Context7 MCP for current library/framework/SDK/API/CLI documentation: resolve the library ID first, then query a focused concept. Prefer the alternate Context7 connector if one connection fails authentication. Use official primary documentation when no relevant Context7 documentation is available. General refactoring and business-logic changes do not need a documentation lookup.

## Documentation and feature work

Keep `README.md` a short end-user showcase. Put practical guides in `docs/` and link them through `docs/README.md`; keep the source map and contributor workflow in `CONTRIBUTING.md`. `docs/STATUS.md` records current evidence and blockers; archive superseded detail under `docs/history/` without changing historical claims. Run the offline documentation checker when moving links or assets.

New features must flow through the shared engine where applicable, present actual state and actionable errors, and cover policy boundaries, cancellation, and cleanup. Preserve persisted keys and diagnostic codes unless an intentional migration is documented. Avoid speculative abstractions and dependencies.

Use genuine app captures in `docs/assets/`, with descriptive alt text and provenance. Isolate screenshot stores from user data; never fabricate a successful export, include credentials/session links, or start sharing for presentation. Keep images compact and check every capture before publication.

## Git and release

Keep commits meaningful, cohesive, and logically organized. Make commits whenever a reasonable, coherent set of changes is complete and relevant verification has passed; avoid unnecessary fragmentation or letting completed work accumulate into one large uncommitted batch. Stage only changes belonging to that commit, preserving unrelated in-progress work. Use clear, professional, imperative commit messages that accurately describe the final consolidated change.

Proactively amend, squash, or consolidate commits when appropriate and safe, especially when newer commits fix, refine, or expand the same logical change. Prefer amending the latest commit when continuing that change; squash related work-in-progress commits, follow-up fixes, and minor refinements into a single well-described commit when appropriate. Preserve separate commits for independently meaningful features, changes, or milestones, and retain useful checkpoints during active development. Keep the workflow efficient and maintainable; avoid excessive history cleanup with little practical benefit.

Before rewriting history, verify whether the affected commits are shared or published. Never rewrite shared or published history without explicit authorization, and do not force-push unless explicitly requested.

Audit reachable history as well as the working tree for credentials and private data before a first push. Use `main` for reviewed releases and `codex/` branches for agent work.

Run `scripts/check.sh` before a release. Release packaging must fail closed for missing production signing/notarization credentials unless local mode was explicitly selected. A public release requires the qualification checklist in `docs/RELEASING.md`; outstanding device tests are release blockers, not assumed passes.

Use the shared ARM64 build settings and verify exact architecture, deployment target, and SDK metadata for every packaged executable. Optional executable helpers must retain pinned ARM64 archive/executable integrity checks.

Keep one current local application at `dist/LoadSide.app` and expose its bundled CLI through `dist/loadside`. Local ZIPs require `scripts/package.sh --local --archive`; production archives remain versioned and non-overwriting. Use `scripts/clean.sh` for generated build/cache cleanup, retaining `dist` by default. Never include imported signing material or user IPA exports in general project cleanup.

