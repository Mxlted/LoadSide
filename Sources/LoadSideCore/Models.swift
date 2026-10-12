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
    public init(ipa: URL, certificate: URL, password: String, profiles: [URL], injections: [URL] = [], output: URL, bundleIdentifier: String? = nil, displayName: String? = nil, removeExtensions: Bool = false, entitlementPolicy: EntitlementPolicy = .strict, bundleIdentifierPolicy: BundleIdentifierPolicy = .automatic) {
        self.ipa = ipa; self.certificate = certificate; self.password = password
        self.profiles = profiles; self.injections = injections; self.output = output
        self.bundleIdentifier = bundleIdentifier; self.displayName = displayName
        self.bundleIdentifierPolicy = bundleIdentifierPolicy
        self.removeExtensions = removeExtensions
        self.entitlementPolicy = entitlementPolicy
    }
}

public enum BundleIdentifierPolicy: String, Codable, Sendable, CaseIterable {
    /// Keep an authorized original ID, otherwise use one unambiguous exact profile App ID.
    case automatic
    /// Require profiles to authorize the source ID unless an explicit override is supplied.
    case preserve
}

public enum EntitlementPolicy: String, Codable, Sendable, CaseIterable {
    case strict
    case compatible
}

public enum SigningStage: String, Codable, Sendable, CaseIterable {
    case preparing, inspecting, credentials, entitlements, injecting, signing, verifying, exporting, completed
    public var title: String {
        switch self {
        case .preparing: "Prepare workspace"
        case .inspecting: "Inspect application"
        case .credentials: "Validate credentials"
        case .injecting: "Inject libraries"
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
    public init(output: URL, bundleIdentifier: String, displayName: String, certificateName: String, teamIdentifier: String, signedCodeCount: Int, injectedLibraryCount: Int, warnings: [String], sha256: String, completedAt: Date = Date()) {
        self.output = output; self.bundleIdentifier = bundleIdentifier; self.displayName = displayName
        self.certificateName = certificateName; self.teamIdentifier = teamIdentifier
        self.signedCodeCount = signedCodeCount; self.injectedLibraryCount = injectedLibraryCount
        self.warnings = warnings; self.sha256 = sha256; self.completedAt = completedAt
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
