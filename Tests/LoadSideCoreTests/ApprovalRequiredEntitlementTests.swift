import XCTest
@testable import LoadSideCore

final class ApprovalRequiredEntitlementTests: XCTestCase {
    private func claim(for entry: ApprovalRequiredEntitlements.Entry) -> Any {
        if let restricted = entry.restrictedValues { return restricted.sorted() }
        return true
    }

    func testCatalogHasUniqueExactKeysAndPrimarySources() {
        let entries = ApprovalRequiredEntitlements.entries
        XCTAssertEqual(Set(entries.map(\.key)).count, entries.count)
        // Guard against accidentally restoring the original two-entry implementation.
        XCTAssertGreaterThan(entries.count, 100)
        for entry in entries {
            XCTAssertFalse(entry.key.contains("*"))
            XCTAssertFalse(entry.name.isEmpty)
            XCTAssertFalse(entry.sources.isEmpty)
            for source in entry.sources {
                XCTAssertEqual(URL(string: source)?.host, "developer.apple.com")
                XCTAssertEqual(URL(string: source)?.scheme, "https")
            }
        }
    }

    func testEveryCatalogedClaimIsOmittedAndLoggedForDistributionInBothPolicies() throws {
        let profile = try testProfile()
        for entry in ApprovalRequiredEntitlements.entries {
            for policy in EntitlementPolicy.allCases {
                var logged: [String] = []
                let result = try EntitlementResolver.resolve(requested: [entry.key: claim(for: entry)], profile: profile,
                    bundleIdentifier: "com.example.app.extension", policy: policy) { logged.append($0) }
                XCTAssertNil(result.values[entry.key], entry.key)
                XCTAssertEqual(result.warnings.count, 1, entry.key)
                XCTAssertEqual(logged, result.warnings)
                XCTAssertTrue(logged.first?.contains(entry.name) == true, entry.key)
                XCTAssertTrue(logged.first?.contains(entry.key) == true, entry.key)
                XCTAssertTrue(logged.first?.contains("com.example.app.extension") == true, entry.key)
            }
        }
    }

    func testEveryAuthorizedCatalogedClaimIsPreservedAndNeverAddedWhenUnrequested() throws {
        for entry in ApprovalRequiredEntitlements.entries {
            for policy in EntitlementPolicy.allCases {
                for development in [false, true] {
                    let profile = try testProfile(extras: [entry.key: claim(for: entry), "get-task-allow": development])
                    let result = try EntitlementResolver.resolve(requested: [entry.key: claim(for: entry)], profile: profile,
                        bundleIdentifier: "com.example.app", policy: policy)
                    XCTAssertTrue(NSDictionary(dictionary: [entry.key: claim(for: entry)]).isEqual(to: [entry.key: try XCTUnwrap(result.values[entry.key])]), entry.key)
                    XCTAssertTrue(result.warnings.isEmpty, entry.key)
                    let empty = try EntitlementResolver.resolve(requested: [:], profile: profile,
                        bundleIdentifier: "com.example.app", policy: policy)
                    XCTAssertNil(empty.values[entry.key], entry.key)
                }
            }
        }
    }

    func testDistributionOnlyRulesDoNotRelaxDevelopmentValidation() throws {
        let profile = try testProfile(extras: ["get-task-allow": true])
        for entry in ApprovalRequiredEntitlements.entries {
            if entry.scope == .distributionOnly {
                XCTAssertThrowsError(try EntitlementResolver.resolve(requested: [entry.key: claim(for: entry)], profile: profile,
                    bundleIdentifier: "com.example.app", policy: .strict), entry.key)
                let compatible = try EntitlementResolver.resolve(requested: [entry.key: claim(for: entry)], profile: profile,
                    bundleIdentifier: "com.example.app", policy: .compatible)
                XCTAssertNil(compatible.values[entry.key], entry.key)
                XCTAssertTrue(compatible.warnings.first?.contains("Removed unsupported entitlement") == true, entry.key)
            } else {
                let result = try EntitlementResolver.resolve(requested: [entry.key: claim(for: entry)], profile: profile,
                    bundleIdentifier: "com.example.app", policy: .strict)
                XCTAssertNil(result.values[entry.key], entry.key)
                XCTAssertTrue(result.warnings.first?.contains("Omitted Apple-approval") == true, entry.key)
            }
        }
    }

    func testArrayDictionaryAndStringClaimsStillRequireValueAuthorization() throws {
        let claims: [(String, Any, Any)] = [
            ("com.apple.developer.sensorkit.reader.allow", ["ambient-light-sensor"], ["on-wrist"]),
            ("com.apple.developer.in-app-identity-presentment", ["document-types": ["us-drivers-license"]], ["document-types": ["other"]]),
            ("com.apple.developer.memory.transfer_send", "com.example.browser", "com.other.browser"),
            ("com.apple.developer.storekit.custom-purchase-link.allowed-regions", ["jp"], ["br"])
        ]
        for (key, requested, denied) in claims {
            for policy in EntitlementPolicy.allCases {
                let authorized = try EntitlementResolver.resolve(requested: [key: requested], profile: testProfile(extras: [key: requested]),
                    bundleIdentifier: "com.example.app", policy: policy)
                XCTAssertTrue(NSDictionary(dictionary: [key: requested]).isEqual(to: [key: try XCTUnwrap(authorized.values[key])]))
                XCTAssertTrue(authorized.warnings.isEmpty)
                for allowed in [denied, NSNumber(value: true)] {
                    let omitted = try EntitlementResolver.resolve(requested: [key: requested], profile: testProfile(extras: [key: allowed]),
                        bundleIdentifier: "com.example.app", policy: policy)
                    XCTAssertNil(omitted.values[key])
                    XCTAssertEqual(omitted.warnings.count, 1)
                }
            }
        }
    }

    func testSharedKeysOmitOnlyUnauthorizedManagedValues() throws {
        let cases = [
            ("com.apple.developer.healthkit.access", "verifiable-health-records", ["health-records"]),
            ("com.apple.developer.user-fonts", "font-enumeration", ["app-usage", "system-installation"])
        ]
        for (key, managed, ordinary) in cases {
            for policy in EntitlementPolicy.allCases {
                let profile = try testProfile(extras: [key: ordinary])
                let result = try EntitlementResolver.resolve(requested: [key: ordinary + [managed]], profile: profile,
                    bundleIdentifier: "com.example.app", policy: policy)
                XCTAssertEqual(result.values[key] as? [String], ordinary)
                XCTAssertEqual(result.warnings.count, 1)
                XCTAssertTrue(result.warnings[0].contains("values [\(managed)]"))

                let fullProfile = try testProfile(extras: [key: ordinary + [managed]])
                let preserved = try EntitlementResolver.resolve(requested: [key: ordinary + [managed]], profile: fullProfile,
                    bundleIdentifier: "com.example.app", policy: policy)
                XCTAssertEqual(preserved.values[key] as? [String], ordinary + [managed])
                XCTAssertTrue(preserved.warnings.isEmpty)
            }
        }
    }

    func testSharedKeysKeepOrdinaryChecksAndLogBeforeFailure() throws {
        let key = "com.apple.developer.healthkit.access"
        var logged: [String] = []
        XCTAssertThrowsError(try EntitlementResolver.resolve(
            requested: [key: ["health-records", "verifiable-health-records"]], profile: testProfile(),
            bundleIdentifier: "com.example.app", policy: .strict) { logged.append($0) })
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("values [verifiable-health-records]"))
        let compatible = try EntitlementResolver.resolve(
            requested: [key: ["health-records", "verifiable-health-records"]], profile: testProfile(),
            bundleIdentifier: "com.example.app", policy: .compatible)
        XCTAssertNil(compatible.values[key])
        XCTAssertEqual(compatible.warnings.count, 2)
        XCTAssertTrue(compatible.warnings[1].contains("Removed unsupported entitlement"))

        // A managed claim authorized by the profile cannot hide an ordinary failure.
        logged = []
        XCTAssertThrowsError(try EntitlementResolver.resolve(
            requested: [key: ["health-records", "verifiable-health-records"]],
            profile: testProfile(extras: [key: ["verifiable-health-records"]]),
            bundleIdentifier: "com.example.app", policy: .strict) { logged.append($0) })
        XCTAssertTrue(logged.isEmpty)
    }

    func testSharedKeysDoNotClassifyMalformedOrUnknownValues() throws {
        for (key, ordinary, managed) in [
            ("com.apple.developer.healthkit.access", "health-records", "verifiable-health-records"),
            ("com.apple.developer.user-fonts", "app-usage", "font-enumeration")
        ] {
            let malformed: [Any] = [true, managed, [managed, 42] as [Any], [ordinary], ["unknown-future-value"]]
            for value in malformed {
                var logged: [String] = []
                XCTAssertThrowsError(try EntitlementResolver.resolve(requested: [key: value], profile: testProfile(),
                    bundleIdentifier: "com.example.app", policy: .strict) { logged.append($0) })
                XCTAssertTrue(logged.isEmpty)
            }
        }
    }

    func testExactCaseSensitiveManagedKeysAreRecognized() throws {
        for key in ["com.apple.CommCenter.fine-grained", "com.apple.developer.networking.HotspotHelper",
                    "com.apple.developer.cs.allow-jit", "com.apple.developer.cs.jit-write-allowlist"] {
            XCTAssertNotNil(ApprovalRequiredEntitlements.entry(for: key, profile: try testProfile()))
        }
    }

    func testOrdinaryCapabilitiesUnknownKeysAndNearMatchesAreNotClassified() throws {
        let keys = ["application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups", "get-task-allow",
            "aps-environment", "com.apple.developer.associated-domains", "com.apple.security.application-groups",
            "com.apple.developer.networking.networkextension", "com.apple.developer.networking.HotspotConfiguration",
            "com.apple.developer.proximity-reader.identity.display", "com.apple.developer.in-app-payments",
            "com.apple.developer.nfc.readersession.formats", "com.apple.developer.messages.critical-messaging",
            "com.apple.developer.driverkit.communicates-with-drivers", "com.apple.developer.driverkit.allow-third-party-userclients",
            "com.apple.developer.family-controls.app-and-website-usage", "com.apple.developer.fileprovider.testing-mode",
            "com.apple.security.cs.allow-jit", "com.apple.developer.kernel.extended-virtual-addressing",
            "com.apple.developer.submerged-shallow-depth-and-pressure", "com.apple.developer.healthkit",
            "com.apple.commcenter.fine-grained", "com.apple.developer.networking.hotspothelper",
            "com.apple.developer.carplay-audio.unknown", "com.apple.developer.driverkit.unknown",
            "com.apple.developer.coremedia.allow-alternate-video-decoder-selection", "com.apple.developer.storekit.request-data"]
        for key in keys {
            XCTAssertNil(ApprovalRequiredEntitlements.entry(for: key, profile: try testProfile()), key)
        }
        for key in keys.dropFirst(4) {
            XCTAssertThrowsError(try EntitlementResolver.resolve(requested: [key: true], profile: testProfile(),
                bundleIdentifier: "com.example.app", policy: .strict), key)
        }
    }
}
