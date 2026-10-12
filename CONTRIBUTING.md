# Contributing

Read `AGENTS.md` and `docs/ARCHITECTURE.md` before changing the signing pipeline. Open `Package.swift` in Xcode or use the Swift CLI. macOS 14+ and Swift 6+ are required.

Keep changes focused and add meaningful tests for parsing, policy, cleanup, or export behavior. Unit tests must not require real credentials, network access, or the login keychain. Native-tool integration tests may use generated fixtures in private temporary directories, but must not weaken production trust checks.

Run `scripts/check.sh` before submitting. For archive and binary changes, include malformed-input and traversal coverage. For entitlement changes, include explicit/wildcard profiles, type mismatches, team/app-prefix differences, extension cases, and strict/compatible outcomes. For process changes, cover cancellation, timeout, bounded output, and cleanup.

Pull requests should explain the behavior change, evidence from tests, and remaining device qualification. Never claim installation support based solely on a synthetic signature. Update the changelog and compatibility documentation when the supported surface changes.
