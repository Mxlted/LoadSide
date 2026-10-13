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
    /// Identifier used to select the main signing profile, independent of Info.plist.
    public let profileBundleIdentifier: String
    public let reason: String
    public var changesIdentifier: Bool { originalIdentifier != effectiveIdentifier }
    public var usesProfileIdentity: Bool { effectiveIdentifier != profileBundleIdentifier }

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
        guard let main = bundles.first(where: { $0.url == mainApp }) else {
            throw LoadSideError("ipa.main", "The IPA has no valid main application.")
        }
        try BundleInventory.validateMachO(in: mainApp)
        return IPAInspection(
            displayName: main.info["CFBundleDisplayName"] as? String ?? main.info["CFBundleName"] as? String
                ?? mainApp.deletingPathExtension().lastPathComponent,
            bundleIdentifier: main.identifier,
            extensionBundleIdentifiers: bundles.filter { $0.url.pathExtension.lowercased() == "appex" }.map(\.identifier).sorted(),
            nestedAppBundleIdentifiers: bundles.filter { $0.url != mainApp && $0.url.pathExtension.lowercased() == "app" }.map(\.identifier)
                .sorted())
    }

    /// Pure App ID planning. Callers must label this as profile-only preflight:
    /// the signing engine separately verifies that the selected P12 is authorized.
    public static func suggestBundleIdentifier(
        original: String, profiles: [ProvisioningProfile],
        policy: BundleIdentifierPolicy = .preserve,
        override: String? = nil, nestedOriginalIdentifiers: [String] = []
    ) throws -> BundleIdentifierSuggestion {
        guard !profiles.isEmpty else {
            throw LoadSideError("preflight.profiles", "Add a provisioning profile to resolve the app’s bundle identifier.")
        }
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            try validateIdentifier(override)
            guard profiles.contains(where: { $0.matches(bundleIdentifier: override) }) else {
                throw LoadSideError(
                    "bundleIdentifier.overrideNotAuthorized",
                    "The supplied profiles do not authorize the requested bundle identifier \(override). Allowed App IDs: \(patterns(profiles)).",
                    recovery:
                        "Enter an identifier allowed by the profile, select Automatic, or supply a matching profile. A certificate cannot expand a profile’s App ID authorization."
                )
            }
            return BundleIdentifierSuggestion(
                originalIdentifier: original, effectiveIdentifier: override, profileBundleIdentifier: override,
                reason: "Using the explicit bundle identifier override. The signing certificate is checked separately.")
        }
        try validateIdentifier(original)
        if profiles.contains(where: { $0.matches(bundleIdentifier: original) }) {
            return BundleIdentifierSuggestion(
                originalIdentifier: original, effectiveIdentifier: original, profileBundleIdentifier: original,
                reason: "The supplied profiles authorize the original bundle identifier. The signing certificate is checked separately.")
        }
        let exact = Set(profiles.map(\.bundleIdentifierPattern).filter { !$0.contains("*") })
        // Recognize a main profile plus profiles for the actual nested bundles,
        // without guessing from an arbitrary shared reverse-DNS prefix.
        // Profiles matching retained original child IDs are not main candidates.
        let nested = Set(nestedOriginalIdentifiers)
        let mainCandidates = exact.subtracting(nested)
        let candidates = mainCandidates.filter { candidate in
            let mapped = Set(
                [candidate]
                    + nestedOriginalIdentifiers.filter { $0.hasPrefix(original + ".") }.map {
                        candidate + $0.dropFirst(original.count)
                    })
            return exact.isSubset(of: mapped.union(nested))
        }
        guard candidates.count == 1, let identifier = candidates.first else {
            if exact.isEmpty {
                throw LoadSideError(
                    "bundleIdentifier.overrideRequired",
                    "The original identifier \(original) does not match the profile wildcard patterns: \(patterns(profiles)).",
                    recovery:
                        "Enter an explicit bundle identifier within an allowed pattern. LoadSide will not invent an app identity from a wildcard."
                )
            }
            throw LoadSideError(
                "bundleIdentifier.ambiguous",
                "The main signing profile for \(original) is not unambiguous. Supplied exact App IDs: \(exact.sorted().prefix(6).joined(separator: ", ")).",
                recovery:
                    "Supply one main profile plus any matching nested profiles, or enter an authorized bundle identifier override. LoadSide will not guess which unrelated profile should provide the main signing identity."
            )
        }
        try validateIdentifier(identifier)
        if policy == .preserve {
            return BundleIdentifierSuggestion(
                originalIdentifier: original, effectiveIdentifier: original, profileBundleIdentifier: identifier,
                reason:
                    "Keeps \(original) in the app’s metadata and uses the supplied profile’s signing identity for \(identifier). These identifiers differ; device installation and runtime behavior are unverified."
            )
        }
        return BundleIdentifierSuggestion(
            originalIdentifier: original, effectiveIdentifier: identifier, profileBundleIdentifier: identifier,
            reason:
                "Automatic selection uses the unambiguous main profile App ID, \(identifier), accounting for profiles matching the app’s nested bundles. Prefix-related nested IDs will follow this change. The signing certificate is checked separately."
        )
    }

    static func resolveForSigning(
        original: String, profiles: [ProvisioningProfile], certificate: Data,
        policy: BundleIdentifierPolicy, override: String?, nestedOriginalIdentifiers: [String] = []
    ) throws -> BundleIdentifierSuggestion {
        let authorized = profiles.filter { $0.developerCertificates.contains(certificate) }
        guard !authorized.isEmpty else {
            throw LoadSideError(
                "profile.noMatch", "No supplied profile contains the selected signing certificate.",
                recovery: "Use a P12 whose exact certificate is listed in the profile’s DeveloperCertificates.")
        }
        let requested = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        if policy == .preserve, requested == nil || requested == "",
            profiles.contains(where: { $0.matches(bundleIdentifier: original) }),
            !authorized.contains(where: { $0.matches(bundleIdentifier: original) })
        {
            throw LoadSideError(
                "profile.noMatch", "The supplied profile matching \(original) does not contain the selected signing certificate.",
                recovery:
                    "Use its matching P12 or replace that profile. Profile identity reuse cannot hide an incompatible matching profile.")
        }
        return try suggestBundleIdentifier(
            original: original, profiles: authorized, policy: policy, override: override,
            nestedOriginalIdentifiers: nestedOriginalIdentifiers)
    }

    static func validateIdentifier(_ identifier: String) throws {
        guard identifier.count <= 255, identifier.contains("."),
            identifier.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            })
        else {
            throw LoadSideError(
                "request.bundleID", "The bundle identifier must use nonempty dot-separated ASCII letters, digits, and hyphens.")
        }
    }

    private static func patterns(_ profiles: [ProvisioningProfile]) -> String {
        Set(profiles.map(\.bundleIdentifierPattern)).sorted().prefix(6).joined(separator: ", ")
    }
}
