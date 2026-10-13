import Security
import XCTest

@testable import LoadSideCore

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
        XCTAssertThrowsError(
            try EntitlementResolver.resolve(
                requested: ["aps-environment": "development"], profile: testProfile(), bundleIdentifier: "com.example.app", policy: .strict)
        ) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "entitlements.unsupported")
        }
    }

    func testCompatibleRemovesAndExplainsUnsupportedCapabilities() throws {
        let result = try EntitlementResolver.resolve(
            requested: ["aps-environment": "development"], profile: testProfile(), bundleIdentifier: "com.example.app", policy: .compatible)
        XCTAssertNil(result.values["aps-environment"])
        XCTAssertTrue(result.warnings.contains { $0.contains("aps-environment") })
    }

    func testApprovalRequiredCapabilitiesAreOmittedAndLoggedInBothPolicies() throws {
        let requested: [String: Any] = [
            "com.apple.developer.networking.multicast": true,
            "com.apple.developer.device-information.user-assigned-device-name": true
        ]
        for policy in EntitlementPolicy.allCases {
            var logged: [String] = []
            let result = try EntitlementResolver.resolve(
                requested: requested, profile: testProfile(), bundleIdentifier: "com.example.app.extension", policy: policy
            ) { logged.append($0) }
            XCTAssertEqual(logged, result.warnings)
            XCTAssertEqual(logged.count, 2)
            for key in requested.keys {
                XCTAssertNil(result.values[key])
                XCTAssertTrue(
                    logged.contains {
                        $0.contains(key) && $0.contains("com.example.app.extension") && $0.contains("Apple-approval")
                            && $0.contains("may stop working")
                    })
            }
            XCTAssertTrue(logged.contains { $0.contains("Multicast Networking") })
            XCTAssertTrue(logged.contains { $0.contains("User-Assigned Device Name") })
        }
    }

    func testApprovalRequiredCapabilitiesArePreservedOnlyWhenAuthorized() throws {
        for key in ["com.apple.developer.networking.multicast", "com.apple.developer.device-information.user-assigned-device-name"] {
            for policy in EntitlementPolicy.allCases {
                let authorized = try EntitlementResolver.resolve(
                    requested: [key: true], profile: testProfile(extras: [key: true]), bundleIdentifier: "com.example.app", policy: policy)
                XCTAssertEqual(authorized.values[key] as? Bool, true)
                XCTAssertTrue(authorized.warnings.isEmpty)
                for denied: Any in [false, NSNumber(value: 1), "true"] {
                    let omitted = try EntitlementResolver.resolve(
                        requested: [key: true], profile: testProfile(extras: [key: denied]), bundleIdentifier: "com.example.app",
                        policy: policy)
                    XCTAssertNil(omitted.values[key])
                    XCTAssertEqual(omitted.warnings.count, 1)
                }
                let unrequested = try EntitlementResolver.resolve(
                    requested: [:], profile: testProfile(extras: [key: true]), bundleIdentifier: "com.example.app", policy: policy)
                XCTAssertNil(unrequested.values[key])
                XCTAssertTrue(unrequested.warnings.isEmpty)
            }
        }
    }

    func testApprovalOmissionsAreLoggedEvenWhenAnotherEntitlementBlocksStrictSigning() throws {
        for key in [
            "aps-environment", "com.apple.security.application-groups", "com.apple.developer.declared-age-range",
            "com.apple.developer.coremedia.allow-alternate-video-decoder-selection", "com.apple.developer.storekit.request-data",
            "com.apple.developer.networking.multicast.unknown", "get-task-allow"
        ] {
            var logged: [String] = []
            XCTAssertThrowsError(
                try EntitlementResolver.resolve(
                    requested: [key: true, "com.apple.developer.networking.multicast": true], profile: testProfile(),
                    bundleIdentifier: "com.example.app", policy: .strict
                ) { logged.append($0) }
            ) { error in
                XCTAssertEqual((error as? LoadSideError)?.code, "entitlements.unsupported")
                XCTAssertTrue((error as? LoadSideError)?.message.contains("“\(key)”") == true)
            }
            XCTAssertEqual(logged.count, 1)
            XCTAssertTrue(logged.first?.contains("Multicast Networking") == true)
        }
    }

    func testAssociatedDomainsProfileWildcardPreservesRequestedArrayInBothPolicies() throws {
        let key = "com.apple.developer.associated-domains"
        let domains = ["applinks:www.youtube.com", "applinks:youtu.be", "webcredentials:google.com", "applinks:*.example.com"]
        for allowed: Any in ["*", ["*"]] {
            let profile = try testProfile(extras: [key: allowed])
            for policy in EntitlementPolicy.allCases {
                let result = try EntitlementResolver.resolve(
                    requested: [key: domains], profile: profile, bundleIdentifier: "com.example.app", policy: policy)
                XCTAssertEqual(result.values[key] as? [String], domains)
                XCTAssertTrue(result.warnings.isEmpty)
            }
            let unrequested = try EntitlementResolver.resolve(
                requested: [:], profile: profile, bundleIdentifier: "com.example.app", policy: .strict)
            XCTAssertNil(unrequested.values[key])
        }
    }

    func testAssociatedDomainsStillRequiresProfileAuthorizationAndArrayClaims() throws {
        let key = "com.apple.developer.associated-domains"
        for allowed: Any in [false, "applinks:example.com", ["applinks:other.example.com"]] {
            XCTAssertThrowsError(
                try EntitlementResolver.resolve(
                    requested: [key: ["applinks:example.com"]], profile: testProfile(extras: [key: allowed]),
                    bundleIdentifier: "com.example.app", policy: .strict))
        }
        XCTAssertThrowsError(
            try EntitlementResolver.resolve(
                requested: [key: ["applinks:example.com"]], profile: testProfile(), bundleIdentifier: "com.example.app", policy: .strict))
        for malformed: Any in ["*", ["*"], [""], [true], [["applinks:example.com"]], ["applinks:example.com", 1]] {
            XCTAssertThrowsError(
                try EntitlementResolver.resolve(
                    requested: [key: malformed], profile: testProfile(extras: [key: "*"]), bundleIdentifier: "com.example.app",
                    policy: .strict))
        }
        let exactDomains = ["applinks:*.example.com"]
        let exact = try EntitlementResolver.resolve(
            requested: [key: exactDomains], profile: testProfile(extras: [key: exactDomains]), bundleIdentifier: "com.example.app",
            policy: .strict)
        XCTAssertEqual(exact.values[key] as? [String], exactDomains)
        // The special profile representation cannot broaden unrelated entitlements.
        XCTAssertFalse(EntitlementResolver.isAllowed(["group.example"], by: "*"))
        XCTAssertFalse(EntitlementResolver.isAllowed(["TEAM.*"], by: ["TEAM.*"]))
    }

    func testIdentityMigrationPreservesAuthorizedSharedGroups() throws {
        let result = try EntitlementResolver.resolve(
            requested: ["application-identifier": "OLD.com.old.app", "keychain-access-groups": ["OLD.com.old.app", "OLD.shared"]],
            profile: testProfile(), bundleIdentifier: "com.example.app", policy: .strict)
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
        XCTAssertEqual(
            try ProvisioningProfile.select(from: [wildcard, exact], bundleIdentifier: "com.example.app", certificate: Data([1, 2, 3])).uuid,
            exact.uuid)
        XCTAssertThrowsError(try ProvisioningProfile.select(from: [exact], bundleIdentifier: "com.example.app", certificate: Data([9])))
        let duplicate = try testProfile(id: "NEWTEAM.com.example.app")
        XCTAssertThrowsError(
            try ProvisioningProfile.select(from: [exact, duplicate], bundleIdentifier: "com.example.app", certificate: Data([1, 2, 3])))
    }

    func testExpiredProfileRejected() { XCTAssertThrowsError(try testProfile(expiration: Date().addingTimeInterval(-1))) }

    func testExactMainAppProfileCannotAuthorizeExtensionAfterIdentifierRewrite() throws {
        let profile = try testProfile(id: "NEWTEAM.com.target.app")
        let plan = try SigningPreflight.suggestBundleIdentifier(original: "com.original.app", profiles: [profile], policy: .automatic)
        let extensionID = plan.identifier(forOriginalBundleIdentifier: "com.original.app.OpenYoutube.Extension")
        XCTAssertEqual(extensionID, "com.target.app.OpenYoutube.Extension")
        XCTAssertFalse(profile.matches(bundleIdentifier: extensionID))
        XCTAssertThrowsError(try ProvisioningProfile.select(from: [profile], bundleIdentifier: extensionID, certificate: Data([1, 2, 3]))) {
            error in
            XCTAssertEqual((error as? LoadSideError)?.code, "profile.noMatch")
        }
    }

    func testWildcardProfileCanBeReusedForMainAppAndExtension() throws {
        let profile = try testProfile()
        for identifier in ["com.example.app", "com.example.app.OpenYoutube.Extension"] {
            XCTAssertEqual(
                try ProvisioningProfile.select(from: [profile], bundleIdentifier: identifier, certificate: Data([1, 2, 3])).uuid,
                profile.uuid)
            let claims = try EntitlementResolver.resolve(requested: [:], profile: profile, bundleIdentifier: identifier, policy: .strict)
            XCTAssertEqual(claims.values["application-identifier"] as? String, "NEWTEAM.\(identifier)")
        }
        XCTAssertThrowsError(
            try ProvisioningProfile.select(
                from: [profile], bundleIdentifier: "com.example.app.OpenYoutube.Extension", certificate: Data([9])))
    }

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
        let result = try EntitlementResolver.resolve(
            requested: ["get-task-allow": false], profile: profile, bundleIdentifier: "com.example.app", policy: .strict)
        XCTAssertNil(result.values["get-task-allow"])
    }

    func testDebuggerAccessUsesExplicitEntitlementPolicy() throws {
        XCTAssertThrowsError(
            try EntitlementResolver.resolve(
                requested: ["get-task-allow": true], profile: testProfile(), bundleIdentifier: "com.example.app", policy: .strict))
        let result = try EntitlementResolver.resolve(
            requested: ["get-task-allow": true], profile: testProfile(), bundleIdentifier: "com.example.app", policy: .compatible)
        XCTAssertNil(result.values["get-task-allow"])
        XCTAssertTrue(result.warnings.contains { $0.contains("get-task-allow") })
    }

    func testIntegerDebuggerClaimCannotBypassStrictPolicyAsFalseBoolean() throws {
        let requested = ["get-task-allow": NSNumber(value: 0)]
        for profile in [try testProfile(), try testProfile(extras: ["get-task-allow": false])] {
            XCTAssertThrowsError(
                try EntitlementResolver.resolve(
                    requested: requested, profile: profile, bundleIdentifier: "com.example.app", policy: .strict)
            ) {
                XCTAssertEqual(($0 as? LoadSideError)?.code, "entitlements.unsupported")
            }
            let compatible = try EntitlementResolver.resolve(
                requested: requested, profile: profile, bundleIdentifier: "com.example.app", policy: .compatible)
            XCTAssertNil(compatible.values["get-task-allow"])
            XCTAssertEqual(compatible.warnings.count, 1)
            XCTAssertTrue(compatible.warnings[0].contains("get-task-allow"))
        }
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
