import Foundation
import LoadSideCore

enum JobMode: String, Codable, CaseIterable {
    case sign, injectOnly
    var title: String { self == .sign ? "Sign & export" : "Inject only" }
}

enum JobStatus: String, Codable {
    case running, completed, failed, cancelled, interrupted
    var title: String { rawValue.capitalized }
}

struct JobRecord: Identifiable, Codable {
    var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var sourceName: String
    var status: JobStatus
    var output: URL
    var result: SigningResult?
    var events: [SigningEvent]
    var failure: String?
    var recovery: String?
    var errorCode: String?
    var entitlementPolicy: EntitlementPolicy
    var profileCount: Int
    var injectionNames: [String]
    var removeExtensions: Bool?
    var bundleIdentifierPolicy: BundleIdentifierPolicy?
    var savedSigningProfileID: UUID?
    var extensionProfilePolicy: ExtensionProfilePolicy?
    var jobMode: JobMode?
    var injectionResult: InjectionExportResult?
}
