import XCTest
import Security
@testable import LoadSideCore

func testProfile(id: String = "NEWTEAM.com.example.*", uuid: String = UUID().uuidString,
                 certificate: Data = Data([1, 2, 3]), extras: [String: Any] = [:], expiration: Date = Date().addingTimeInterval(86_400)) throws -> ProvisioningProfile {
    var entitlements: [String: Any] = ["application-identifier": id, "com.apple.developer.team-identifier": "NEWTEAM", "keychain-access-groups": ["NEWTEAM.*"], "get-task-allow": false]
    entitlements.merge(extras) { _, new in new }
    let payload: [String: Any] = ["UUID": uuid, "Name": "Fixture", "TeamIdentifier": ["NEWTEAM"], "ApplicationIdentifierPrefix": ["NEWTEAM"],
                                  "Entitlements": entitlements, "ExpirationDate": expiration, "CreationDate": Date().addingTimeInterval(-60),
                                  "DeveloperCertificates": [certificate], "ProvisionedDevices": ["fixture-device"], "Platform": ["iOS"]]
    let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    return try ProvisioningProfile(url: URL(fileURLWithPath: "/fixture.mobileprovision"), payload: data, data: data)
}

final class EntitlementTests: XCTestCase {
    func testUnsignedClaimsOnlyMinimumNotProfileAllowlist() throws {
        let profile = try testProfile(extras: ["aps-environment": "production", "com.apple.developer.associated-domains": ["*"]])
        let result = try EntitlementResolver.resolve(requested: [:], profile: profile, bundleIdentifier: "com.example.app", policy: .strict)
        XCTAssertEqual(result.values["application-identifier"] as? String, "NEWTEAM.com.example.app")
        XCTAssertNil(result.values["aps-environment"])
        XCTAssertNil(result.values["com.apple.developer.associated-domains"])
        XCTAssertEqual(result.values.count, 3)
    }

    func testStrictRejectsUnsupportedEntitlement() throws {
        XCTAssertThrowsError(try EntitlementResolver.resolve(requested: ["aps-environment": "development"], profile: testProfile(), bundleIdentifier: "com.example.app", policy: .strict)) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "entitlements.unsupported")
        }
    }

    func testCompatibleRemovesAndExplainsUnsupportedCapabilities() throws {
        let result = try EntitlementResolver.resolve(requested: ["aps-environment": "development"], profile: testProfile(), bundleIdentifier: "com.example.app", policy: .compatible)
        XCTAssertNil(result.values["aps-environment"])
        XCTAssertTrue(result.warnings.contains { $0.contains("aps-environment") })
    }

    func testIdentityMigrationPreservesAuthorizedSharedGroups() throws {
        let result = try EntitlementResolver.resolve(requested: ["application-identifier": "OLD.com.old.app", "keychain-access-groups": ["OLD.com.old.app", "OLD.shared"]], profile: testProfile(), bundleIdentifier: "com.example.app", policy: .strict)
        XCTAssertEqual(result.values["keychain-access-groups"] as? [String], ["NEWTEAM.com.example.app", "NEWTEAM.shared"])
        XCTAssertNil(result.values["get-task-allow"])
    }

    func testWildcardCannotEscapePrefixOrIntroduceClaimsWithWildcards() {
        XCTAssertTrue(EntitlementResolver.matches("TEAM.com.example.app", allowed: "TEAM.com.example.*"))
        XCTAssertFalse(EntitlementResolver.matches("OTHER.com.example.app", allowed: "TEAM.*"))
        XCTAssertFalse(EntitlementResolver.matches("TEAM.*", allowed: "TEAM.*"))
        XCTAssertFalse(EntitlementResolver.matches("TEAM.com.example.app", allowed: "TEAM.*.app"))
        XCTAssertFalse(EntitlementResolver.isAllowed(["group.allowed", "group.other"], by: ["group.allowed"]))
        XCTAssertFalse(EntitlementResolver.isAllowed(NSNumber(value: 1), by: NSNumber(value: true)))
    }

    func testProfileSelectionRequiresExactCertificateAndPrefersSpecificity() throws {
        let wildcard = try testProfile()
        let exact = try testProfile(id: "NEWTEAM.com.example.app")
        XCTAssertEqual(try ProvisioningProfile.select(from: [wildcard, exact], bundleIdentifier: "com.example.app", certificate: Data([1, 2, 3])).uuid, exact.uuid)
        XCTAssertThrowsError(try ProvisioningProfile.select(from: [exact], bundleIdentifier: "com.example.app", certificate: Data([9])))
        XCTAssertThrowsError(try ProvisioningProfile.select(from: [exact, testProfile(id: "NEWTEAM.com.example.app")], bundleIdentifier: "com.example.app", certificate: Data([1, 2, 3])))
    }

    func testExpiredProfileRejected() { XCTAssertThrowsError(try testProfile(expiration: Date().addingTimeInterval(-1))) }

    func testProfilePlatformCannotAuthorizeDifferentDevicePlatform() throws {
        let profile = try testProfile()
        XCTAssertTrue(profile.supports(machOPlatform: 2))
        XCTAssertTrue(profile.supports(machOPlatform: 4))
        XCTAssertFalse(profile.supports(machOPlatform: 3))
        XCTAssertFalse(profile.supports(machOPlatform: 7))
    }

    func testTrustServiceFailureIsNotMisreportedAsUntrustedCertificate() throws {
        let serviceError = CFErrorCreate(nil, kCFErrorDomainOSStatus, Int(errSecInternalComponent), nil)
        XCTAssertEqual(ProvisioningProfile.trustEvaluationFailure(serviceError).code, "profile.trustUnavailable")
        let certificateError = CFErrorCreate(nil, kCFErrorDomainOSStatus, Int(errSecCertificateExpired), nil)
        XCTAssertEqual(ProvisioningProfile.trustEvaluationFailure(certificateError).code, "profile.trust")
    }

    func testDevelopmentProfileDoesNotGrantUnrequestedDebuggerAccess() throws {
        let profile = try testProfile(extras: ["get-task-allow": true])
        let result = try EntitlementResolver.resolve(requested: ["get-task-allow": false], profile: profile, bundleIdentifier: "com.example.app", policy: .strict)
        XCTAssertNil(result.values["get-task-allow"])
    }

    func testDebuggerAccessUsesExplicitEntitlementPolicy() throws {
        XCTAssertThrowsError(try EntitlementResolver.resolve(requested: ["get-task-allow": true], profile: testProfile(), bundleIdentifier: "com.example.app", policy: .strict))
        let result = try EntitlementResolver.resolve(requested: ["get-task-allow": true], profile: testProfile(), bundleIdentifier: "com.example.app", policy: .compatible)
        XCTAssertNil(result.values["get-task-allow"])
        XCTAssertTrue(result.warnings.contains { $0.contains("get-task-allow") })
    }

    func testUnsignedPlistCannotMasqueradeAsTrustedProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("forged.mobileprovision")
        try testProfile().data.write(to: file)
        XCTAssertThrowsError(try ProvisioningProfile.inspect(file))
    }
}
