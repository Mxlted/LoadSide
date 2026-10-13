import SwiftUI

/// Stable preference identifiers are independent of display text and topic order.
enum DisclosureID: String, CaseIterable {
    case extensions = "signing.extensions"
    case compatibility = "signing.compatibility"
    case extensionIdentifiers = "signing.extensionIdentifiers"
    case entitlements = "signing.entitlements"
    case appOverrides = "signing.appOverrides"
    case chooseIPA = "help.chooseIPA"
    case chooseIdentity = "help.chooseIdentity"
    case reviewPlan = "help.reviewPlan"
    case signAndExport = "help.signAndExport"
    case saveProfile = "help.saveProfile"
    case rememberPassword = "help.rememberPassword"
    case manageProfiles = "help.manageProfiles"
    case bundleIdentity = "help.bundleIdentity"
    case keepExtensions = "help.keepExtensions"
    case strictPolicy = "help.strictPolicy"
    case extensionCompatibility = "help.extensionCompatibility"
    case profileEligibility = "help.profileEligibility"
    case injectUnsigned = "help.injectUnsigned"
    case supportedInputs = "help.supportedInputs"
    case debLayout = "help.debLayout"
    case runtimeCompatibility = "help.runtimeCompatibility"
    case findExports = "help.findExports"
    case shareNetwork = "help.shareNetwork"
    case installationLinks = "help.installationLinks"
    case cancelRetry = "help.cancelRetry"
    case inspectActivity = "help.inspectActivity"
    case installationRequirements = "help.installationRequirements"

    var isHelp: Bool { rawValue.hasPrefix("help.") }
    var initiallyExpanded: Bool { !isHelp && self != .appOverrides }
}

/// Presentation preferences contain only disclosure flags, never signing inputs.
@MainActor
final class DisclosurePreferences: ObservableObject {
    private static let storageKey = "disclosureExpansion"
    private let defaults: UserDefaults
    @Published private var values: [String: Bool]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.dictionary(forKey: Self.storageKey) as? [String: Bool] ?? [:]
    }

    func isExpanded(_ id: DisclosureID) -> Bool {
        values[id.rawValue] ?? id.initiallyExpanded
    }

    func setExpanded(_ expanded: Bool, for id: DisclosureID) {
        values[id.rawValue] = expanded
        defaults.set(values, forKey: Self.storageKey)
    }

    func binding(_ id: DisclosureID) -> Binding<Bool> {
        Binding(get: { self.isExpanded(id) }, set: { self.setExpanded($0, for: id) })
    }

    func setAllHelpExpanded(_ expanded: Bool) {
        var updated = values
        for id in DisclosureID.allCases where id.isHelp { updated[id.rawValue] = expanded }
        values = updated
        defaults.set(values, forKey: Self.storageKey)
    }
}
