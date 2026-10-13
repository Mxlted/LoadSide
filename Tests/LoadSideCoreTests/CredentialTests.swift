import Security
import XCTest

@testable import LoadSideCore

final class CredentialTests: XCTestCase {
    /// Synthetic self-signed identity tests isolation/import; it cannot authorize iOS installation.
    func testP12ImportsIntoDisposableKeychainAndValidatesMembership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("key.pem")
        let cert = directory.appendingPathComponent("cert.pem")
        let der = directory.appendingPathComponent("cert.der")
        let p12 = directory.appendingPathComponent("identity.p12")
        let config = directory.appendingPathComponent("openssl.cnf")
        try """
        [req]
        distinguished_name=dn
        x509_extensions=extensions
        prompt=no
        [dn]
        CN=LoadSide Synthetic Test Identity
        [extensions]
        basicConstraints=critical,CA:false
        keyUsage=critical,digitalSignature
        extendedKeyUsage=codeSigning
        """.write(to: config, atomically: true, encoding: .utf8)
        let runner = ProcessRunner()
        _ = try await runner.run(
            "/usr/bin/openssl",
            ["req", "-x509", "-newkey", "rsa:2048", "-keyout", key.path, "-out", cert.path, "-days", "1", "-nodes", "-config", config.path])
        _ = try await runner.run("/usr/bin/openssl", ["x509", "-in", cert.path, "-outform", "DER", "-out", der.path])
        // The fixed fixture password is public test data, never a user credential.
        _ = try await runner.run(
            "/usr/bin/openssl",
            ["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:fixture-password"])
        let profile = try testProfile(certificate: Data(contentsOf: der))
        let before = try await runner.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        var identity: SigningIdentity? = try SigningIdentity(
            p12: p12, password: "fixture-password", workspace: directory, profiles: [profile])
        let keychainPath = try XCTUnwrap(identity?.keychainURL)
        XCTAssertEqual(identity?.name, "LoadSide Synthetic Test Identity")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keychainPath.path))
        let binary = directory.appendingPathComponent("signed-echo")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: binary)
        let claims = directory.appendingPathComponent("entitlements.plist")
        let expectedClaims: [String: Any] = [
            "application-identifier": "NEWTEAM.com.example.fixture", "com.apple.developer.team-identifier": "NEWTEAM"
        ]
        try PropertyListSerialization.data(fromPropertyList: expectedClaims, format: .xml, options: 0).write(to: claims)
        _ = try await runner.run(
            "/usr/bin/codesign",
            [
                "--force", "--sign", try XCTUnwrap(identity?.fingerprint), "--keychain", keychainPath.path, "--timestamp=none",
                "--generate-entitlement-der", "--entitlements", claims.path, binary.path
            ], timeout: 15)
        _ = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", binary.path])
        let signedClaims = try await runner.run("/usr/bin/codesign", ["--display", "--entitlements", "-", "--xml", binary.path])
        XCTAssertEqual(
            try PropertyListSerialization.propertyList(from: signedClaims.stdout, format: nil) as? NSDictionary,
            expectedClaims as NSDictionary)
        let during = try await runner.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        XCTAssertEqual(before.stdout, during.stdout, "Import must not change the user's keychain search list")
        identity = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: keychainPath.path))
        let after = try await runner.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        XCTAssertEqual(before.stdout, after.stdout)
        XCTAssertThrowsError(try SigningIdentity(p12: p12, password: "wrong-password", workspace: directory, profiles: [profile]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keychainPath.path))
        XCTAssertThrowsError(
            try SigningIdentity(
                p12: p12, password: "fixture-password", workspace: directory, profiles: [testProfile(certificate: Data([0]))]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keychainPath.path))
    }
}
