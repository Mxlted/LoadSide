import XCTest
@testable import LoadSideCore

final class SigningPreflightTests: XCTestCase {
    func testAutomaticPreservesOriginalWhenWildcardAuthorizesIt() throws {
        let suggestion = try SigningPreflight.suggestBundleIdentifier(original: "com.example.source", profiles: [testProfile()])
        XCTAssertEqual(suggestion.effectiveIdentifier, "com.example.source")
        XCTAssertFalse(suggestion.changesIdentifier)
    }

    func testUniqueExplicitProfileResolvesMainAndNestedPrefix() throws {
        let suggestion = try SigningPreflight.suggestBundleIdentifier(original: "com.original.app", profiles: [testProfile(id: "NEWTEAM.com.target.app")])
        XCTAssertEqual(suggestion.effectiveIdentifier, "com.target.app")
        XCTAssertTrue(suggestion.changesIdentifier)
        XCTAssertEqual(suggestion.identifier(forOriginalBundleIdentifier: "com.original.app.widget"), "com.target.app.widget")
        XCTAssertEqual(suggestion.identifier(forOriginalBundleIdentifier: "com.original.apples"), "com.original.apples")
        XCTAssertEqual(suggestion.identifier(forOriginalBundleIdentifier: "unrelated.watch.app"), "unrelated.watch.app")
    }

    func testPreserveRequiresOriginalAuthorization() throws {
        XCTAssertThrowsError(try SigningPreflight.suggestBundleIdentifier(original: "com.original.app", profiles: [testProfile(id: "NEWTEAM.com.target.app")], policy: .preserve)) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "bundleIdentifier.preservedNotAuthorized")
        }
    }

    func testExplicitOverrideWinsAndCannotBypassProfilePattern() throws {
        let profiles = [try testProfile(id: "NEWTEAM.com.target.*")]
        let suggestion = try SigningPreflight.suggestBundleIdentifier(original: "com.original.app", profiles: profiles, policy: .preserve, override: "com.target.override")
        XCTAssertEqual(suggestion.effectiveIdentifier, "com.target.override")
        XCTAssertThrowsError(try SigningPreflight.suggestBundleIdentifier(original: "com.target.original", profiles: profiles, override: "com.unrelated.override")) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "bundleIdentifier.overrideNotAuthorized")
        }
    }

    func testAmbiguousProfilesAreNeverGuessed() throws {
        let profiles = [try testProfile(id: "NEWTEAM.com.target.one"), try testProfile(id: "NEWTEAM.com.target.two")]
        XCTAssertThrowsError(try SigningPreflight.suggestBundleIdentifier(original: "com.original.app", profiles: profiles)) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "bundleIdentifier.ambiguous")
        }
        XCTAssertThrowsError(try SigningPreflight.suggestBundleIdentifier(original: "com.original.app", profiles: [testProfile(id: "NEWTEAM.com.target.*")])) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "bundleIdentifier.overrideRequired")
        }
    }

    func testSigningResolutionFiltersByExactCertificateBeforeChoosingIdentity() throws {
        let authorized = try testProfile(id: "NEWTEAM.com.target.app", certificate: Data([1]))
        let differentCertificate = try testProfile(id: "NEWTEAM.com.original.app", certificate: Data([2]))
        // UI-only preview can match a profile; the engine must check the actual P12.
        let preview = try SigningPreflight.suggestBundleIdentifier(original: "com.original.app", profiles: [authorized, differentCertificate])
        XCTAssertEqual(preview.effectiveIdentifier, "com.original.app")
        let actual = try SigningPreflight.resolveForSigning(original: "com.original.app", profiles: [authorized, differentCertificate], certificate: Data([1]), policy: .automatic, override: nil)
        XCTAssertEqual(actual.effectiveIdentifier, "com.target.app")
        XCTAssertThrowsError(try SigningPreflight.resolveForSigning(original: "com.original.app", profiles: [authorized], certificate: Data([3]), policy: .automatic, override: nil))
    }

    func testInspectionAndStagedIdentityRewritePreserveSourceIPAAndPlists() throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("original")
        let app = tree.appendingPathComponent("Payload/Source.app")
        for (url, identifier) in [(app, "com.original.app"), (app.appendingPathComponent("PlugIns/Share.appex"), "com.original.app.share"), (app.appendingPathComponent("Watch/Companion.app"), "com.original.app.watch")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try BinaryFixtures.macho().write(to: url.appendingPathComponent("Code"))
            try BundleInventory.writeInfo(["CFBundleExecutable": "Code", "CFBundleIdentifier": identifier, "CFBundleDisplayName": "Source App"], to: url)
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
        let plan = try SigningPreflight.suggestBundleIdentifier(original: inspection.bundleIdentifier, profiles: [testProfile(id: "NEWTEAM.com.target.app")])
        try BundleInventory.rewriteIdentifiers(in: BundleInventory.discover(in: stagedApp), original: plan.originalIdentifier, replacement: plan.effectiveIdentifier)
        XCTAssertEqual(Set(try BundleInventory.discover(in: stagedApp).map(\.identifier)), ["com.target.app", "com.target.app.share", "com.target.app.watch"])
        XCTAssertEqual(try Data(contentsOf: ipa), originalIPA)
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Info.plist")), originalPlist)
    }

    func testAutomaticIsTheDefaultRequestPolicy() {
        let placeholder = URL(fileURLWithPath: "/placeholder")
        XCTAssertEqual(SigningRequest(ipa: placeholder, certificate: placeholder, password: "", profiles: [], output: placeholder).bundleIdentifierPolicy, .automatic)
    }
}
