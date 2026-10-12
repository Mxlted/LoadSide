import Foundation

public struct IPAInspection: Codable, Sendable {
    public let displayName: String
    public let bundleIdentifier: String
    public let extensionBundleIdentifiers: [String]
    public let nestedAppBundleIdentifiers: [String]
    public var extensionCount: Int { extensionBundleIdentifiers.count }
}

/// A profile-based suggestion, not a certificate or installation eligibility verdict.
public struct BundleIdentifierSuggestion: Sendable {
    public let originalIdentifier: String
    public let effectiveIdentifier: String
    public let reason: String
    public var changesIdentifier: Bool { originalIdentifier != effectiveIdentifier }

    public func identifier(forOriginalBundleIdentifier identifier: String) -> String {
        if identifier == originalIdentifier { return effectiveIdentifier }
        if identifier.hasPrefix(originalIdentifier + ".") { return effectiveIdentifier + identifier.dropFirst(originalIdentifier.count) }
        return identifier
    }
}

public enum SigningPreflight {
    /// Safely inspect a private extracted copy. No credentials are read or imported.
    /// Call from a worker task; extraction and code inspection are cancellation-aware.
    public static func inspectIPA(_ url: URL) throws -> IPAInspection {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LoadSideError("request.ipa", "The source IPA must be a regular local file.")
        }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("LoadSide-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Task.checkCancellation()
        let extracted = workspace.appendingPathComponent("archive")
        try Archive.extract(url, to: extracted)
        let mainApp = try BundleInventory.mainApp(in: extracted)
        let bundles = try BundleInventory.discover(in: mainApp)
        guard let main = bundles.first(where: { $0.url == mainApp }) else { throw LoadSideError("ipa.main", "The IPA has no valid main application.") }
        try BundleInventory.validateMachO(in: mainApp)
        return IPAInspection(displayName: main.info["CFBundleDisplayName"] as? String ?? main.info["CFBundleName"] as? String ?? mainApp.deletingPathExtension().lastPathComponent,
                             bundleIdentifier: main.identifier,
                             extensionBundleIdentifiers: bundles.filter { $0.url.pathExtension.lowercased() == "appex" }.map(\.identifier).sorted(),
                             nestedAppBundleIdentifiers: bundles.filter { $0.url != mainApp && $0.url.pathExtension.lowercased() == "app" }.map(\.identifier).sorted())
    }

    /// Pure App ID planning. Callers must label this as profile-only preflight:
    /// the signing engine separately verifies that the selected P12 is authorized.
    public static func suggestBundleIdentifier(original: String, profiles: [ProvisioningProfile],
                                                policy: BundleIdentifierPolicy = .automatic,
                                                override: String? = nil) throws -> BundleIdentifierSuggestion {
        guard !profiles.isEmpty else { throw LoadSideError("preflight.profiles", "Add a provisioning profile to resolve the app’s bundle identifier.") }
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            try validateIdentifier(override)
            guard profiles.contains(where: { $0.matches(bundleIdentifier: override) }) else {
                throw LoadSideError("bundleIdentifier.overrideNotAuthorized", "The supplied profiles do not authorize the requested bundle identifier \(override). Allowed App IDs: \(patterns(profiles)).", recovery: "Enter an identifier allowed by the profile, select Automatic, or supply a matching profile. A certificate cannot expand a profile’s App ID authorization.")
            }
            return BundleIdentifierSuggestion(originalIdentifier: original, effectiveIdentifier: override, reason: "Using the explicit bundle identifier override. The signing certificate is checked separately.")
        }
        try validateIdentifier(original)
        if profiles.contains(where: { $0.matches(bundleIdentifier: original) }) {
            return BundleIdentifierSuggestion(originalIdentifier: original, effectiveIdentifier: original, reason: "The supplied profiles authorize the original bundle identifier. The signing certificate is checked separately.")
        }
        guard policy == .automatic else {
            throw LoadSideError("bundleIdentifier.preservedNotAuthorized", "Preserve mode keeps \(original), but the supplied profiles authorize \(patterns(profiles)).", recovery: "Select Automatic to use an unambiguous profile App ID, enter a permitted override, or add a profile matching the original app.")
        }
        let exact = Set(profiles.map(\.bundleIdentifierPattern).filter { !$0.contains("*") })
        guard exact.count == 1, let identifier = exact.first else {
            if exact.isEmpty {
                throw LoadSideError("bundleIdentifier.overrideRequired", "The original identifier \(original) does not match the profile wildcard patterns: \(patterns(profiles)).", recovery: "Enter an explicit bundle identifier within an allowed pattern. LoadSide will not invent an app identity from a wildcard.")
            }
            throw LoadSideError("bundleIdentifier.ambiguous", "Several exact profile App IDs could replace \(original): \(exact.sorted().prefix(6).joined(separator: ", ")).", recovery: "Choose the main app’s bundle identifier explicitly, or remove unrelated profiles. Additional retained extensions may still require their own profiles.")
        }
        try validateIdentifier(identifier)
        return BundleIdentifierSuggestion(originalIdentifier: original, effectiveIdentifier: identifier,
                                          reason: "Automatic selection uses the only exact profile App ID, \(identifier), because the original ID is not authorized. Prefix-related nested IDs will follow this change. The signing certificate is checked separately.")
    }

    static func resolveForSigning(original: String, profiles: [ProvisioningProfile], certificate: Data,
                                  policy: BundleIdentifierPolicy, override: String?) throws -> BundleIdentifierSuggestion {
        let authorized = profiles.filter { $0.developerCertificates.contains(certificate) }
        guard !authorized.isEmpty else { throw LoadSideError("profile.noMatch", "No supplied profile contains the selected signing certificate.", recovery: "Use a P12 whose exact certificate is listed in the profile’s DeveloperCertificates.") }
        return try suggestBundleIdentifier(original: original, profiles: authorized, policy: policy, override: override)
    }

    static func validateIdentifier(_ identifier: String) throws {
        guard identifier.count <= 255, identifier.contains("."), identifier.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }) else {
            throw LoadSideError("request.bundleID", "The bundle identifier must use nonempty dot-separated ASCII letters, digits, and hyphens.")
        }
    }

    private static func patterns(_ profiles: [ProvisioningProfile]) -> String {
        Set(profiles.map(\.bundleIdentifierPattern)).sorted().prefix(6).joined(separator: ", ")
    }
}
