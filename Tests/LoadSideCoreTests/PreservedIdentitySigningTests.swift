import XCTest

@testable import LoadSideCore

final class PreservedIdentitySigningTests: XCTestCase {
    /// Synthetic profiles and ad-hoc signatures exercise archive and signature
    /// composition only. They cannot establish iOS installation eligibility.
    func testNativeSigningRoundTripPreservesMetadataAndUsesExactProfileIdentity() async throws {
        let directory = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceTree = directory.appendingPathComponent("source")
        let sourceApp = sourceTree.appendingPathComponent("Payload/Fixture.app")
        let sourceExtension = sourceApp.appendingPathComponent("PlugIns/Share.appex")
        var originalPlists: [String: Data] = [:]
        for (url, identifier, type) in [(sourceApp, "com.original.app", "APPL"), (sourceExtension, "com.original.app.share", "XPC!")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: url.appendingPathComponent("Code"))
            try BundleInventory.writeInfo(
                [
                    "CFBundleIdentifier": identifier, "CFBundleExecutable": "Code", "CFBundlePackageType": type,
                    "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"
                ], to: url)
            originalPlists[identifier] = try Data(contentsOf: url.appendingPathComponent("Info.plist"))
        }
        let sourceIPA = directory.appendingPathComponent("source.ipa")
        try Archive.createIPA(from: sourceTree, to: sourceIPA)
        let originalArchive = try Data(contentsOf: sourceIPA)
        let originalExecutable = try Data(contentsOf: sourceApp.appendingPathComponent("Code"))
        let stagedTree = directory.appendingPathComponent("staged")
        try Archive.extract(sourceIPA, to: stagedTree)
        let stagedApp = try BundleInventory.mainApp(in: stagedTree)

        let profile = try testProfile(id: "NEWTEAM.com.target.app")
        let plan = try SigningPreflight.resolveForSigning(
            original: "com.original.app", profiles: [profile], certificate: Data([1, 2, 3]),
            policy: .preserve, override: nil, nestedOriginalIdentifiers: ["com.original.app.share"])
        XCTAssertFalse(plan.changesIdentifier)
        XCTAssertTrue(plan.usesProfileIdentity)
        let mainProfile = try ProvisioningProfile.select(
            from: [profile], bundleIdentifier: plan.profileBundleIdentifier, certificate: Data([1, 2, 3]))
        var entitlementFiles: [URL: URL] = [:]
        for (index, bundle) in try BundleInventory.discover(in: stagedApp).enumerated() {
            let selection: BundleProfileSelection
            if bundle.url == stagedApp {
                selection = BundleProfileSelection(profile: mainProfile, usesProfileIdentity: plan.usesProfileIdentity)
            } else {
                selection = try ProvisioningProfile.selectForBundle(
                    from: [profile], bundleIdentifier: bundle.identifier, certificate: Data([1, 2, 3]),
                    mainProfile: mainProfile, mainBundleIdentifier: plan.effectiveIdentifier,
                    isExtension: bundle.url.pathExtension == "appex", policy: .reuseMain)
            }
            let claims = try EntitlementResolver.resolve(
                requested: [
                    "application-identifier": "OLD.\(bundle.identifier)",
                    "keychain-access-groups": ["OLD.\(bundle.identifier)"]
                ],
                profile: selection.profile, bundleIdentifier: bundle.identifier, policy: .strict,
                useProfileIdentity: selection.usesProfileIdentity)
            let claimsURL = directory.appendingPathComponent("claims-\(index).plist")
            try PropertyListSerialization.data(fromPropertyList: claims.values, format: .xml, options: 0).write(to: claimsURL)
            entitlementFiles[bundle.url] = claimsURL
            try selection.profile.data.write(to: bundle.url.appendingPathComponent("embedded.mobileprovision"))
        }

        let runner = ProcessRunner()
        for target in try BundleInventory.signingTargets(in: stagedApp) {
            let claims = try XCTUnwrap(entitlementFiles[target])
            _ = try await runner.run(
                "/usr/bin/codesign",
                ["--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der", "--entitlements", claims.path, target.path])
            _ = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", target.path])
        }
        let outputIPA = directory.appendingPathComponent("signed.ipa")
        try Archive.createIPA(from: stagedTree, to: outputIPA)
        let exportedTree = directory.appendingPathComponent("exported")
        try Archive.extract(outputIPA, to: exportedTree)
        let exportedApp = try BundleInventory.mainApp(in: exportedTree)
        let exportedBundles = try BundleInventory.discover(in: exportedApp)
        XCTAssertEqual(Set(exportedBundles.map(\.identifier)), ["com.original.app", "com.original.app.share"])
        for bundle in exportedBundles {
            _ = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", bundle.url.path])
            let result = try await runner.run("/usr/bin/codesign", ["--display", "--entitlements", "-", "--xml", bundle.url.path])
            let claims = try XCTUnwrap(try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any])
            XCTAssertEqual(claims["application-identifier"] as? String, "NEWTEAM.com.target.app")
            XCTAssertEqual(claims["keychain-access-groups"] as? [String], ["NEWTEAM.com.target.app"])
            XCTAssertEqual(
                try Data(contentsOf: bundle.url.appendingPathComponent("Info.plist")), try XCTUnwrap(originalPlists[bundle.identifier]))
            XCTAssertEqual(try Data(contentsOf: bundle.url.appendingPathComponent("embedded.mobileprovision")), profile.data)
        }
        XCTAssertEqual(try Data(contentsOf: sourceIPA), originalArchive)
        XCTAssertEqual(try Data(contentsOf: sourceApp.appendingPathComponent("Code")), originalExecutable)
        XCTAssertEqual(try Data(contentsOf: sourceApp.appendingPathComponent("Info.plist")), originalPlists["com.original.app"])
        XCTAssertEqual(try Data(contentsOf: sourceExtension.appendingPathComponent("Info.plist")), originalPlists["com.original.app.share"])
    }
}
