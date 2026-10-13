import XCTest

@testable import LoadSideCore

final class SigningPreflightTests: XCTestCase {
    func testDefaultPreservesOriginalAndNestedIdentifiersWhenWildcardAuthorizesThem() throws {
        let suggestion = try SigningPreflight.suggestBundleIdentifier(original: "com.example.source", profiles: [testProfile()])
        XCTAssertEqual(suggestion.effectiveIdentifier, "com.example.source")
        XCTAssertEqual(suggestion.profileBundleIdentifier, "com.example.source")
        XCTAssertEqual(suggestion.identifier(forOriginalBundleIdentifier: "com.example.source.share"), "com.example.source.share")
        XCTAssertFalse(suggestion.changesIdentifier)
        XCTAssertFalse(suggestion.usesProfileIdentity)
    }

    func testDefaultNeverReplacesOriginalWithProfileIdentifier() throws {
        let profile = try testProfile(id: "NEWTEAM.com.target.app")
        let suggestion = try SigningPreflight.suggestBundleIdentifier(original: "com.original.app", profiles: [profile])
        XCTAssertEqual(suggestion.effectiveIdentifier, "com.original.app")
        XCTAssertEqual(suggestion.profileBundleIdentifier, "com.target.app")
        XCTAssertEqual(suggestion.identifier(forOriginalBundleIdentifier: "com.original.app.share"), "com.original.app.share")
        XCTAssertFalse(suggestion.changesIdentifier)
        XCTAssertTrue(suggestion.usesProfileIdentity)
    }

    func testUniqueExplicitProfileResolvesMainAndNestedPrefix() throws {
        let suggestion = try SigningPreflight.suggestBundleIdentifier(
            original: "com.original.app", profiles: [testProfile(id: "NEWTEAM.com.target.app")], policy: .automatic)
        XCTAssertEqual(suggestion.effectiveIdentifier, "com.target.app")
        XCTAssertEqual(suggestion.profileBundleIdentifier, "com.target.app")
        XCTAssertTrue(suggestion.changesIdentifier)
        XCTAssertFalse(suggestion.usesProfileIdentity)
        XCTAssertEqual(suggestion.identifier(forOriginalBundleIdentifier: "com.original.app.widget"), "com.target.app.widget")
        XCTAssertEqual(suggestion.identifier(forOriginalBundleIdentifier: "com.original.apples"), "com.original.apples")
        XCTAssertEqual(suggestion.identifier(forOriginalBundleIdentifier: "unrelated.watch.app"), "unrelated.watch.app")
    }

    func testMatchingOriginalProfileIsPreferredOverUnrelatedExactIdentity() throws {
        let matching = try testProfile(id: "NEWTEAM.com.original.app")
        let unrelated = try testProfile(id: "NEWTEAM.com.target.app")
        let suggestion = try SigningPreflight.suggestBundleIdentifier(
            original: "com.original.app", profiles: [unrelated, matching], policy: .preserve)
        XCTAssertEqual(suggestion.effectiveIdentifier, "com.original.app")
        XCTAssertEqual(suggestion.profileBundleIdentifier, "com.original.app")
        XCTAssertFalse(suggestion.usesProfileIdentity)
    }

    func testExplicitOverrideWinsAndCannotBypassProfilePattern() throws {
        let profiles = [try testProfile(id: "NEWTEAM.com.target.*")]
        let suggestion = try SigningPreflight.suggestBundleIdentifier(
            original: "com.original.app", profiles: profiles, policy: .preserve, override: "com.target.override")
        XCTAssertEqual(suggestion.effectiveIdentifier, "com.target.override")
        XCTAssertEqual(suggestion.profileBundleIdentifier, "com.target.override")
        XCTAssertFalse(suggestion.usesProfileIdentity)
        XCTAssertThrowsError(
            try SigningPreflight.suggestBundleIdentifier(
                original: "com.target.original", profiles: profiles, override: "com.unrelated.override")
        ) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "bundleIdentifier.overrideNotAuthorized")
        }
        XCTAssertThrowsError(
            try SigningPreflight.suggestBundleIdentifier(
                original: "com.original.app", profiles: [testProfile(id: "NEWTEAM.com.target.app")], override: "com.original.app")
        ) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "bundleIdentifier.overrideNotAuthorized")
        }
    }

    func testAmbiguousProfilesAreNeverGuessed() throws {
        let profiles = [try testProfile(id: "NEWTEAM.com.target.one"), try testProfile(id: "NEWTEAM.com.target.two")]
        for policy in [BundleIdentifierPolicy.preserve, .automatic] {
            XCTAssertThrowsError(
                try SigningPreflight.suggestBundleIdentifier(original: "com.original.app", profiles: profiles, policy: policy)
            ) { error in
                XCTAssertEqual((error as? LoadSideError)?.code, "bundleIdentifier.ambiguous")
            }
            XCTAssertThrowsError(
                try SigningPreflight.suggestBundleIdentifier(
                    original: "com.original.app", profiles: [testProfile(id: "NEWTEAM.com.target.*")], policy: policy)
            ) { error in
                XCTAssertEqual((error as? LoadSideError)?.code, "bundleIdentifier.overrideRequired")
            }
        }
    }

    func testSigningResolutionFiltersByExactCertificateBeforeChoosingIdentity() throws {
        let authorized = try testProfile(id: "NEWTEAM.com.target.app", certificate: Data([1]))
        let differentCertificate = try testProfile(id: "NEWTEAM.com.original.app", certificate: Data([2]))
        // UI-only preview can match a profile; the engine must check the actual P12.
        let preview = try SigningPreflight.suggestBundleIdentifier(
            original: "com.original.app", profiles: [authorized, differentCertificate])
        XCTAssertEqual(preview.effectiveIdentifier, "com.original.app")
        let actual = try SigningPreflight.resolveForSigning(
            original: "com.original.app", profiles: [authorized, differentCertificate], certificate: Data([1]), policy: .automatic,
            override: nil)
        XCTAssertEqual(actual.effectiveIdentifier, "com.target.app")
        XCTAssertThrowsError(
            try SigningPreflight.resolveForSigning(
                original: "com.original.app", profiles: [authorized, differentCertificate], certificate: Data([1]), policy: .preserve,
                override: nil)
        ) { error in
            XCTAssertEqual(
                (error as? LoadSideError)?.code, "profile.noMatch", "An incompatible original-ID profile cannot be hidden by identity reuse"
            )
        }
        let preserved = try SigningPreflight.resolveForSigning(
            original: "com.original.app", profiles: [authorized], certificate: Data([1]), policy: .preserve, override: nil)
        XCTAssertEqual(preserved.effectiveIdentifier, "com.original.app")
        XCTAssertEqual(preserved.profileBundleIdentifier, "com.target.app")
        XCTAssertTrue(preserved.usesProfileIdentity)
        XCTAssertThrowsError(
            try SigningPreflight.resolveForSigning(
                original: "com.original.app", profiles: [authorized], certificate: Data([3]), policy: .automatic, override: nil))
        XCTAssertThrowsError(
            try SigningPreflight.resolveForSigning(
                original: "com.original.app", profiles: [authorized], certificate: Data([3]), policy: .preserve, override: nil)
        ) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "profile.noMatch")
        }
    }

    func testInspectionAndStagedIdentityRewritePreserveSourceIPAAndPlists() throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("original")
        let app = tree.appendingPathComponent("Payload/Source.app")
        for (url, identifier) in [
            (app, "com.original.app"), (app.appendingPathComponent("PlugIns/Share.appex"), "com.original.app.share"),
            (app.appendingPathComponent("Watch/Companion.app"), "com.original.app.watch")
        ] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try BinaryFixtures.macho().write(to: url.appendingPathComponent("Code"))
            try BundleInventory.writeInfo(
                ["CFBundleExecutable": "Code", "CFBundleIdentifier": identifier, "CFBundleDisplayName": "Source App"], to: url)
        }
        let originalPlist = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
        let ipa = root.appendingPathComponent("source.ipa")
        try Archive.createIPA(from: tree, to: ipa)
        let originalIPA = try Data(contentsOf: ipa)
        let inspection = try SigningPreflight.inspectIPA(ipa)
        XCTAssertEqual(inspection.displayName, "Source App")
        XCTAssertEqual(inspection.bundleIdentifier, "com.original.app")
        XCTAssertEqual(inspection.extensionBundleIdentifiers, ["com.original.app.share"])
        XCTAssertEqual(inspection.nestedAppBundleIdentifiers, ["com.original.app.watch"])
        XCTAssertEqual(inspection.extensionCount, 1)
        let stagedTree = root.appendingPathComponent("staged")
        try Archive.extract(ipa, to: stagedTree)
        let stagedApp = try BundleInventory.mainApp(in: stagedTree)
        let plan = try SigningPreflight.suggestBundleIdentifier(
            original: inspection.bundleIdentifier, profiles: [testProfile(id: "NEWTEAM.com.target.app")], policy: .automatic)
        try BundleInventory.rewriteIdentifiers(
            in: BundleInventory.discover(in: stagedApp), original: plan.originalIdentifier, replacement: plan.effectiveIdentifier)
        XCTAssertEqual(
            Set(try BundleInventory.discover(in: stagedApp).map(\.identifier)),
            ["com.target.app", "com.target.app.share", "com.target.app.watch"])
        XCTAssertEqual(try Data(contentsOf: ipa), originalIPA)
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Info.plist")), originalPlist)
    }

    func testInspectionIgnoresFinderSidecarAsAnAppWithoutChangingSourceArchive() throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("source")
        let app = tree.appendingPathComponent("Payload/Source.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try BinaryFixtures.macho().write(to: app.appendingPathComponent("Code"))
        try BundleInventory.writeInfo(["CFBundleExecutable": "Code", "CFBundleIdentifier": "com.original.app"], to: app)
        let sidecar = tree.appendingPathComponent("Payload/._Source.app")
        let metadata = Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]) + Data(repeating: 0, count: 18)
        try metadata.write(to: sidecar)
        let ipa = root.appendingPathComponent("source.ipa")
        try Archive.createIPA(from: tree, to: ipa)
        let originalIPA = try Data(contentsOf: ipa)

        let inspection = try SigningPreflight.inspectIPA(ipa)
        XCTAssertEqual(inspection.bundleIdentifier, "com.original.app")
        XCTAssertEqual(inspection.extensionCount, 0)
        XCTAssertEqual(try BundleInventory.signingTargets(in: app), [app])
        XCTAssertEqual(try Data(contentsOf: ipa), originalIPA)
        XCTAssertEqual(try Data(contentsOf: sidecar), metadata)
    }

    func testOriginalIdentifierAndStrictEntitlementsAreTheDefaultRequestPolicies() {
        let placeholder = URL(fileURLWithPath: "/placeholder")
        let request = SigningRequest(ipa: placeholder, certificate: placeholder, password: "", profiles: [], output: placeholder)
        XCTAssertEqual(request.bundleIdentifierPolicy, .preserve)
        XCTAssertNil(request.bundleIdentifier)
        XCTAssertEqual(request.entitlementPolicy, .strict)
    }

    func testMainAndExtensionProfilesResolveUsingActualBundleStructure() throws {
        let main = try testProfile(id: "NEWTEAM.com.target.app")
        let extensionProfile = try testProfile(id: "NEWTEAM.com.target.app.safari")
        let profiles = [main, extensionProfile]
        let plan = try SigningPreflight.suggestBundleIdentifier(
            original: "com.original.app", profiles: profiles, policy: .automatic,
            nestedOriginalIdentifiers: ["com.original.app.safari"])
        XCTAssertEqual(plan.effectiveIdentifier, "com.target.app")
        XCTAssertEqual(plan.identifier(forOriginalBundleIdentifier: "com.original.app.safari"), extensionProfile.bundleIdentifierPattern)
        let preserved = try SigningPreflight.suggestBundleIdentifier(
            original: "com.original.app", profiles: profiles, policy: .preserve,
            nestedOriginalIdentifiers: ["com.original.app.safari"])
        XCTAssertEqual(preserved.effectiveIdentifier, "com.original.app")
        XCTAssertEqual(preserved.profileBundleIdentifier, "com.target.app")
        XCTAssertEqual(preserved.identifier(forOriginalBundleIdentifier: "com.original.app.safari"), "com.original.app.safari")
        XCTAssertTrue(preserved.usesProfileIdentity)
        XCTAssertThrowsError(
            try SigningPreflight.suggestBundleIdentifier(
                original: "com.original.app", profiles: profiles, policy: .automatic,
                nestedOriginalIdentifiers: ["com.original.app.unrelated"]))
        XCTAssertThrowsError(
            try SigningPreflight.suggestBundleIdentifier(
                original: "com.original.app", profiles: profiles + [testProfile(id: "NEWTEAM.com.target.other")], policy: .automatic,
                nestedOriginalIdentifiers: ["com.original.app.safari"]))
    }

    func testPreservedMainUsesItsOwnIdentityWhileOriginalExtensionKeepsMatchingProfile() throws {
        let main = try testProfile(id: "NEWTEAM.com.target.app")
        let child = try testProfile(id: "NEWTEAM.com.original.app.safari")
        let suggestion = try SigningPreflight.suggestBundleIdentifier(
            original: "com.original.app", profiles: [main, child],
            nestedOriginalIdentifiers: ["com.original.app.safari"])
        XCTAssertEqual(suggestion.effectiveIdentifier, "com.original.app")
        XCTAssertEqual(suggestion.profileBundleIdentifier, "com.target.app")
        XCTAssertTrue(suggestion.usesProfileIdentity)
        let extensionSelection = try ProvisioningProfile.selectForBundle(
            from: [main, child], bundleIdentifier: "com.original.app.safari", certificate: Data([1, 2, 3]),
            mainProfile: main, mainBundleIdentifier: suggestion.effectiveIdentifier, isExtension: true, policy: .reuseMain)
        XCTAssertEqual(extensionSelection.profile.uuid, child.uuid)
        XCTAssertFalse(extensionSelection.usesProfileIdentity)
    }

    func testProfilesOnlyForOriginalNestedBundlesCannotBecomeMainSigningIdentity() throws {
        let nestedIdentifiers = ["com.original.app.safari", "com.original.app.watch"]
        let profiles = try nestedIdentifiers.map { try testProfile(id: "NEWTEAM.\($0)") }
        for profileSet in [[profiles[0]], profiles] {
            XCTAssertThrowsError(
                try SigningPreflight.suggestBundleIdentifier(
                    original: "com.original.app", profiles: profileSet,
                    nestedOriginalIdentifiers: nestedIdentifiers))
        }
    }

    func testSameIdentityProfilesStillRequireUnambiguousCertificateSelection() throws {
        let profiles = [try testProfile(id: "NEWTEAM.com.target.app"), try testProfile(id: "NEWTEAM.com.target.app")]
        let suggestion = try SigningPreflight.suggestBundleIdentifier(original: "com.original.app", profiles: profiles)
        XCTAssertTrue(suggestion.usesProfileIdentity)
        XCTAssertThrowsError(
            try ProvisioningProfile.select(
                from: profiles, bundleIdentifier: suggestion.profileBundleIdentifier, certificate: Data([1, 2, 3]))
        ) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "profile.ambiguous")
        }
    }
}
