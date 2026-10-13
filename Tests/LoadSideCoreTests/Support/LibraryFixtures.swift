import Foundation
import CryptoKit
@testable import LoadSideCore

/// Synthetic signed-result metadata paired with deterministic bytes, not an installable IPA.
func libraryResult(_ root: URL, version: String? = "42.1", name: String = "Example", bytes: Int = 512 * 1_024) throws -> SigningResult {
    let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0) }), output = root.appendingPathComponent(UUID().uuidString + ".ipa")
    try data.write(to: output)
    return SigningResult(output: output, bundleIdentifier: "app.example.fixture", displayName: name, certificateName: "Fixture signing certificate",
        teamIdentifier: "TEAMFIXTURE", signedCodeCount: 1, injectedLibraryCount: 0, warnings: [],
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bundleVersion: version)
}
