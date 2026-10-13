import XCTest

@testable import LoadSideApp

final class DisclosurePreferencesTests: XCTestCase {
    @MainActor
    func testFreshDefaultsAndIndividualChoicesSurviveRecreation() throws {
        let suite = "LoadSide-DisclosureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DisclosurePreferences(defaults: defaults)

        for id in [DisclosureID.extensions, .compatibility, .extensionIdentifiers, .entitlements] {
            XCTAssertTrue(preferences.isExpanded(id))
        }
        XCTAssertFalse(preferences.isExpanded(.appOverrides))
        for id in DisclosureID.allCases where id.isHelp { XCTAssertFalse(preferences.isExpanded(id)) }

        preferences.binding(.extensions).wrappedValue = false
        preferences.binding(.compatibility).wrappedValue = false
        preferences.binding(.appOverrides).wrappedValue = true
        preferences.binding(.chooseIPA).wrappedValue = true
        let restored = DisclosurePreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(restored.isExpanded(.extensions))
        XCTAssertFalse(restored.isExpanded(.compatibility))
        XCTAssertTrue(restored.isExpanded(.entitlements))
        XCTAssertTrue(restored.isExpanded(.appOverrides))
        XCTAssertTrue(restored.isExpanded(.chooseIPA))
        XCTAssertFalse(restored.isExpanded(.chooseIdentity))
    }

    @MainActor
    func testHelpBatchActionsPersistEveryTopicWithoutChangingSigningChoices() throws {
        let suite = "LoadSide-DisclosureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DisclosurePreferences(defaults: defaults)
        preferences.setExpanded(false, for: .extensions)
        preferences.setExpanded(true, for: .appOverrides)

        for expanded in [true, false] {
            preferences.setAllHelpExpanded(expanded)
            let restored = DisclosurePreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
            for id in DisclosureID.allCases where id.isHelp { XCTAssertEqual(restored.isExpanded(id), expanded) }
            XCTAssertFalse(restored.isExpanded(.extensions))
            XCTAssertTrue(restored.isExpanded(.entitlements))
            XCTAssertTrue(restored.isExpanded(.appOverrides))
        }
    }
}
