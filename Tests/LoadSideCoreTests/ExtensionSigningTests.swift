import XCTest

@testable import LoadSideCore

final class ExtensionSigningTests: XCTestCase {
    private let certificate = Data([1, 2, 3])

    private func select(
        _ profiles: [ProvisioningProfile], main: ProvisioningProfile,
        identifier: String = "com.target.app.safari", isExtension: Bool = true,
        policy: ExtensionProfilePolicy = .reuseMain, certificate: Data? = nil,
        mainBundleIdentifier: String = "com.target.app"
    ) throws -> BundleProfileSelection {
        try ProvisioningProfile.selectForBundle(
            from: profiles, bundleIdentifier: identifier,
            certificate: certificate ?? self.certificate, mainProfile: main, mainBundleIdentifier: mainBundleIdentifier,
            isExtension: isExtension, policy: policy)
    }

    func testDefaultReusePolicyRetainsEligibleExtensionsAndMatchingPolicyOptsOut() throws {
        let main = try testProfile(id: "NEWTEAM.com.target.app")
        XCTAssertThrowsError(try select([main], main: main, policy: .matching))
        let url = URL(fileURLWithPath: "/placeholder")
        let request = SigningRequest(ipa: url, certificate: url, password: "", profiles: [], output: url)
        XCTAssertEqual(request.extensionProfilePolicy, .reuseMain)
        XCTAssertFalse(request.removeExtensions)
        let selection = try select([main], main: main, policy: request.extensionProfilePolicy)
        XCTAssertTrue(selection.usesProfileIdentity)
        XCTAssertEqual(selection.profile.uuid, main.uuid)
    }

    func testMatchingExtensionProfileAlwaysWins() throws {
        let main = try testProfile(id: "NEWTEAM.com.target.app")
        for matching in [try testProfile(id: "NEWTEAM.com.target.app.safari"), try testProfile(id: "NEWTEAM.com.target.*")] {
            let selection = try select([main, matching], main: main)
            XCTAssertEqual(selection.profile.uuid, matching.uuid)
            XCTAssertFalse(selection.usesProfileIdentity)
        }
    }

    func testReuseCannotHideAmbiguityOrWrongCertificate() throws {
        let main = try testProfile(id: "NEWTEAM.com.target.app")
        let matching = try testProfile(id: "NEWTEAM.com.target.app.safari")
        XCTAssertThrowsError(try select([main, matching, testProfile(id: "NEWTEAM.com.target.app.safari")], main: main)) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "profile.ambiguous")
        }
        XCTAssertThrowsError(try select([main], main: main, certificate: Data([9])))
        XCTAssertThrowsError(try select([main, testProfile(id: "NEWTEAM.com.target.app.safari", certificate: Data([9]))], main: main))
    }

    func testReuseCannotApplyToNestedAppsUnrelatedIDsOrWildcardFallback() throws {
        let main = try testProfile(id: "NEWTEAM.com.target.app")
        XCTAssertThrowsError(try select([main], main: main, isExtension: false))
        XCTAssertThrowsError(try select([main], main: main, identifier: "com.target.apples.safari"))
        XCTAssertThrowsError(try select([main], main: main, identifier: "org.unrelated.safari"))
        let wildcard = try testProfile(id: "NEWTEAM.com.other.*")
        XCTAssertThrowsError(try select([wildcard], main: wildcard))
    }

    func testPreservedOriginalExtensionCanReuseDifferentMainProfileIdentity() throws {
        let main = try testProfile(id: "NEWTEAM.com.target.app")
        XCTAssertTrue(main.canReuseIdentity(forExtension: "com.original.app.safari", mainBundleIdentifier: "com.original.app"))
        let selection = try select([main], main: main, identifier: "com.original.app.safari", mainBundleIdentifier: "com.original.app")
        XCTAssertEqual(selection.profile.uuid, main.uuid)
        XCTAssertTrue(selection.usesProfileIdentity)

        let matching = try testProfile(id: "NEWTEAM.com.original.app.safari")
        let matchedSelection = try select(
            [main, matching], main: main, identifier: "com.original.app.safari", mainBundleIdentifier: "com.original.app")
        XCTAssertEqual(matchedSelection.profile.uuid, matching.uuid)
        XCTAssertFalse(matchedSelection.usesProfileIdentity)
    }

    func testPreservingOriginalDoesNotBroadenExtensionReuseBoundaries() throws {
        let main = try testProfile(id: "NEWTEAM.com.target.app")
        for identifier in ["com.original.app", "com.original.apples.safari", "com.target.app.safari", "org.unrelated.extension"] {
            XCTAssertFalse(main.canReuseIdentity(forExtension: identifier, mainBundleIdentifier: "com.original.app"), identifier)
            XCTAssertThrowsError(
                try select([main], main: main, identifier: identifier, mainBundleIdentifier: "com.original.app"), identifier)
        }
        XCTAssertThrowsError(
            try select(
                [main], main: main, identifier: "com.original.app.watch", isExtension: false, mainBundleIdentifier: "com.original.app"))
        XCTAssertThrowsError(
            try select(
                [main], main: main, identifier: "com.original.app.safari", policy: .matching, mainBundleIdentifier: "com.original.app"))
        XCTAssertThrowsError(
            try select(
                [main], main: main, identifier: "com.original.app.safari", certificate: Data([9]), mainBundleIdentifier: "com.original.app")
        )
        let wrongCertificate = try testProfile(id: "NEWTEAM.com.original.app.safari", certificate: Data([9]))
        XCTAssertThrowsError(
            try select(
                [main, wrongCertificate], main: main, identifier: "com.original.app.safari", mainBundleIdentifier: "com.original.app"))
        let wildcard = try testProfile(id: "NEWTEAM.com.target.*")
        XCTAssertFalse(wildcard.canReuseIdentity(forExtension: "com.original.app.safari", mainBundleIdentifier: "com.original.app"))
        XCTAssertThrowsError(
            try select([wildcard], main: wildcard, identifier: "com.original.app.safari", mainBundleIdentifier: "com.original.app"))
    }

    func testMainProfileIdentityPreservesAuthorizedCapabilitiesWithoutGrantingOthers() throws {
        let main = try testProfile(
            id: "NEWTEAM.com.target.app", extras: ["aps-environment": "production", "com.apple.developer.associated-domains": ["*"]])
        let requested: [String: Any] = [
            "application-identifier": "OLD.com.original.app",
            "keychain-access-groups": ["OLD.com.original.app"],
            "com.apple.developer.associated-domains": ["applinks:example.com"]
        ]
        let resolved = try EntitlementResolver.resolve(
            requested: requested, profile: main, bundleIdentifier: "com.original.app", policy: .strict, useProfileIdentity: true)
        XCTAssertEqual(resolved.values["application-identifier"] as? String, "NEWTEAM.com.target.app")
        XCTAssertEqual(resolved.values["com.apple.developer.team-identifier"] as? String, "NEWTEAM")
        XCTAssertEqual(resolved.values["keychain-access-groups"] as? [String], ["NEWTEAM.com.target.app"])
        XCTAssertEqual(resolved.values["com.apple.developer.associated-domains"] as? [String], ["applinks:example.com"])
        XCTAssertNil(resolved.values["aps-environment"], "A new signing identity must not grant unrequested capabilities")
        XCTAssertThrowsError(
            try EntitlementResolver.resolve(
                requested: requested, profile: testProfile(id: "NEWTEAM.com.target.app"), bundleIdentifier: "com.original.app",
                policy: .strict, useProfileIdentity: true)
        ) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "entitlements.unsupported")
        }
        XCTAssertThrowsError(
            try EntitlementResolver.resolve(
                requested: [:], profile: testProfile(), bundleIdentifier: "com.original.app", policy: .strict, useProfileIdentity: true)
        ) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "entitlements.profileIdentity")
        }
        XCTAssertThrowsError(
            try EntitlementResolver.resolve(
                requested: [:], profile: testProfile(id: "NEWTEAM.com..target"), bundleIdentifier: "com.original.app", policy: .strict,
                useProfileIdentity: true)
        ) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "request.bundleID")
        }
    }

    func testProfileIdentityChangesOnlyIdentityClaimsAndStillValidatesCapabilities() throws {
        let main = try testProfile(id: "NEWTEAM.com.target.app", extras: ["aps-environment": "production"])
        let original: [String: Any] = [
            "application-identifier": "OLD.com.original.app.safari",
            "keychain-access-groups": ["OLD.com.original.app.safari"],
            "com.apple.developer.associated-domains": ["applinks:example.com"]
        ]
        XCTAssertThrowsError(
            try EntitlementResolver.resolve(
                requested: original, profile: main, bundleIdentifier: "com.target.app.safari", policy: .strict, useProfileIdentity: true))
        let resolved = try EntitlementResolver.resolve(
            requested: original, profile: main, bundleIdentifier: "com.target.app.safari", policy: .compatible, useProfileIdentity: true)
        XCTAssertEqual(resolved.values["application-identifier"] as? String, "NEWTEAM.com.target.app")
        XCTAssertEqual(resolved.values["keychain-access-groups"] as? [String], ["NEWTEAM.com.target.app"])
        XCTAssertNil(resolved.values["aps-environment"], "Do not grant capabilities just because the profile allows them")
        XCTAssertNil(resolved.values["com.apple.developer.associated-domains"])
        XCTAssertEqual(resolved.warnings.count, 1)
        XCTAssertThrowsError(
            try EntitlementResolver.resolve(requested: [:], profile: main, bundleIdentifier: "com.target.app.safari", policy: .compatible))
        XCTAssertThrowsError(
            try EntitlementResolver.resolve(
                requested: [:], profile: testProfile(), bundleIdentifier: "com.example.app.safari", policy: .compatible,
                useProfileIdentity: true))
    }

    func testRemovalAndReuseCannotBeRequestedTogether() {
        let url = URL(fileURLWithPath: "/placeholder")
        let request = SigningRequest(
            ipa: url, certificate: url, password: "", profiles: [], output: url, removeExtensions: true, extensionProfilePolicy: .reuseMain)
        XCTAssertThrowsError(try SigningEngine.validate(request)) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "request.extensionPolicy")
        }
    }

    func testRemovalDoesNotImplicitlyEnableReuseAndMatchingPolicyIsPreserved() {
        let url = URL(fileURLWithPath: "/placeholder")
        let removing = SigningRequest(ipa: url, certificate: url, password: "", profiles: [], output: url, removeExtensions: true)
        XCTAssertEqual(removing.extensionProfilePolicy, .matching)
        let matching = SigningRequest(
            ipa: url, certificate: url, password: "", profiles: [], output: url, extensionProfilePolicy: .matching)
        XCTAssertEqual(matching.extensionProfilePolicy, .matching)
        XCTAssertFalse(matching.removeExtensions)
    }
}
