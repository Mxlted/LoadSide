import Foundation

public struct SigningRequest: Sendable {
    public var ipa: URL
    public var certificate: URL
    public var password: String
    public var profiles: [URL]
    public var injections: [URL]
    public var output: URL
    public var bundleIdentifier: String?
    public var bundleIdentifierPolicy: BundleIdentifierPolicy
    public var displayName: String?
    public var removeExtensions: Bool
    public var entitlementPolicy: EntitlementPolicy
    public var extensionProfilePolicy: ExtensionProfilePolicy
    public init(ipa: URL, certificate: URL, password: String, profiles: [URL], injections: [URL] = [], output: URL, bundleIdentifier: String? = nil, displayName: String? = nil, removeExtensions: Bool = false, entitlementPolicy: EntitlementPolicy = .strict, bundleIdentifierPolicy: BundleIdentifierPolicy = .preserve, extensionProfilePolicy: ExtensionProfilePolicy? = nil) {
        self.ipa = ipa; self.certificate = certificate; self.password = password
        self.profiles = profiles; self.injections = injections; self.output = output
        self.bundleIdentifier = bundleIdentifier; self.displayName = displayName
        self.bundleIdentifierPolicy = bundleIdentifierPolicy
        self.removeExtensions = removeExtensions
        self.entitlementPolicy = entitlementPolicy
        // Retained extensions use the compatibility default. Explicit removal
        // has no retained extensions to reuse; an explicit contradictory policy
        // remains intact so request validation can reject it.
        self.extensionProfilePolicy = extensionProfilePolicy ?? (removeExtensions ? .matching : .reuseMain)
    }
}

public enum ExtensionProfilePolicy: String, Codable, Sendable, CaseIterable {
    case matching
    /// Default compatibility experiment: prefer matching profiles, otherwise
    /// retain a child extension's ID with the main profile's exact signing identity.
    /// Device behavior is unverified and every fallback is reported.
    case reuseMain = "reuse-main"
}

public enum BundleIdentifierPolicy: String, Codable, Sendable, CaseIterable {
    /// Keep an authorized original ID, otherwise use one unambiguous exact profile App ID.
    case automatic
    /// Default: retain the source metadata ID. Prefer matching profiles, otherwise
    /// sign using an unambiguous exact profile identity and report the mismatch.
    case preserve
}

public enum EntitlementPolicy: String, Codable, Sendable, CaseIterable {
    case strict
    case compatible
}

public enum SigningStage: String, Codable, Sendable, CaseIterable {
    case preparing, inspecting, credentials, entitlements, injecting, strippingSignatures, validating, signing, verifying, exporting, completed
    public var title: String {
        switch self {
        case .preparing: "Prepare workspace"
        case .inspecting: "Inspect application"
        case .credentials: "Validate credentials"
        case .injecting: "Inject libraries"
        case .strippingSignatures: "Remove old signatures"
        case .validating: "Validate prepared app"
        case .entitlements: "Resolve entitlements"
        case .signing: "Sign nested code"
        case .verifying: "Verify signatures"
        case .exporting: "Export IPA"
        case .completed: "Export complete"
        }
    }
}

public struct SigningEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    public let stage: SigningStage
    public let fraction: Double
    public let message: String
    public let level: Level
    public enum Level: String, Codable, Sendable { case info, warning, error }
    public init(stage: SigningStage, fraction: Double, message: String, level: Level = .info) {
        id = UUID(); date = Date(); self.stage = stage
        self.fraction = min(1, max(0, fraction)); self.message = message; self.level = level
    }

    /// Redaction changes only the diagnostic, preserving the engine event's identity and time.
    public func redacting(secret: String) -> SigningEvent {
        guard !secret.isEmpty else { return self }
        return SigningEvent(original: self, message: message.replacingOccurrences(of: secret, with: "[redacted]"))
    }

    private init(original: SigningEvent, message: String) {
        id = original.id
        date = original.date
        stage = original.stage
        fraction = original.fraction
        level = original.level
        self.message = message
    }
}

public struct SigningResult: Codable, Sendable {
    public let output: URL
    public let bundleIdentifier: String
    public let displayName: String
    public let certificateName: String
    public let teamIdentifier: String
    public let signedCodeCount: Int
    public let injectedLibraryCount: Int
    public let warnings: [String]
    public let sha256: String
    public let completedAt: Date
    public let bundleVersion: String?
    public init(output: URL, bundleIdentifier: String, displayName: String, certificateName: String, teamIdentifier: String, signedCodeCount: Int, injectedLibraryCount: Int, warnings: [String], sha256: String, completedAt: Date = Date(), bundleVersion: String? = nil) {
        self.output = output; self.bundleIdentifier = bundleIdentifier; self.displayName = displayName
        self.certificateName = certificateName; self.teamIdentifier = teamIdentifier
        self.signedCodeCount = signedCodeCount; self.injectedLibraryCount = injectedLibraryCount
        self.warnings = warnings; self.sha256 = sha256; self.completedAt = completedAt
        self.bundleVersion = bundleVersion
    }
}

/// Preparation only: this request never imports an identity or signs code.
public struct InjectionRequest: Sendable {
    public var ipa: URL
    public var injections: [URL]
    public var output: URL
    public var displayName: String?
    public var removeExtensions: Bool
    public init(ipa: URL, injections: [URL], output: URL, displayName: String? = nil, removeExtensions: Bool = false) {
        self.ipa = ipa; self.injections = injections; self.output = output
        self.displayName = displayName; self.removeExtensions = removeExtensions
    }
}

/// An unsigned prepared archive. It is not a device-installable signing result.
public struct InjectionExportResult: Codable, Sendable {
    public let output: URL
    public let bundleIdentifier: String
    public let displayName: String
    public let injectedLibraryCount: Int
    public let warnings: [String]
    public let sha256: String
    public let completedAt: Date
    public var requiresSigning: Bool { true }

    public init(output: URL, bundleIdentifier: String, displayName: String, injectedLibraryCount: Int, warnings: [String], sha256: String, completedAt: Date = Date()) {
        self.output = output; self.bundleIdentifier = bundleIdentifier; self.displayName = displayName
        self.injectedLibraryCount = injectedLibraryCount; self.warnings = warnings
        self.sha256 = sha256; self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case output, bundleIdentifier, displayName, injectedLibraryCount, warnings, sha256, completedAt, requiresSigning
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        output = try values.decode(URL.self, forKey: .output)
        bundleIdentifier = try values.decode(String.self, forKey: .bundleIdentifier)
        displayName = try values.decode(String.self, forKey: .displayName)
        injectedLibraryCount = try values.decode(Int.self, forKey: .injectedLibraryCount)
        warnings = try values.decode([String].self, forKey: .warnings)
        sha256 = try values.decode(String.self, forKey: .sha256)
        completedAt = try values.decode(Date.self, forKey: .completedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(output, forKey: .output)
        try values.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(injectedLibraryCount, forKey: .injectedLibraryCount)
        try values.encode(warnings, forKey: .warnings)
        try values.encode(sha256, forKey: .sha256)
        try values.encode(completedAt, forKey: .completedAt)
        try values.encode(requiresSigning, forKey: .requiresSigning)
    }
}

public struct LoadSideError: LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let recovery: String
    public init(_ code: String, _ message: String, recovery: String = "Review the diagnostics and try again.") {
        self.code = code; self.message = message; self.recovery = recovery
    }
    public var errorDescription: String? { message }
    public var recoverySuggestion: String? { recovery }
}
