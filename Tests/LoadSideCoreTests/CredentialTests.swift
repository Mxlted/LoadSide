import Security
import XCTest

@testable import LoadSideCore

final class CredentialTests: XCTestCase {
    private struct KeychainConfiguration: Equatable {
        let searchList: Data
        let defaultKeychain: Data
    }

    private func keychainConfiguration(_ runner: ProcessRunner) async throws -> KeychainConfiguration {
        let searchList = try await runner.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        let defaultKeychain = try await runner.run("/usr/bin/security", ["default-keychain", "-d", "user"])
        return KeychainConfiguration(
            searchList: searchList.stdout + searchList.stderr,
            defaultKeychain: defaultKeychain.stdout + defaultKeychain.stderr)
    }

    private func findCertificate(_ name: String, in keychain: SecKeychain? = nil) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: name,
            kSecUseDataProtectionKeychain as String: false, kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    /// Inspect only this test's generated identity, never the user's keychain items.
    private func fixtureIdentityDiagnostic(_ identity: SigningIdentity, runner: ProcessRunner) async throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchSearchList as String: [identity.keychain],
            kSecUseDataProtectionKeychain as String: false,
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let identityStatus = SecItemCopyMatching(query as CFDictionary, &result)
        var diagnostic = "Scoped identity lookup status: \(identityStatus)"
        if identityStatus == errSecSuccess, let result {
            let reference = result as! SecIdentity
            var key: SecKey?
            let keyStatus = SecIdentityCopyPrivateKey(reference, &key)
            diagnostic += "; private key status: \(keyStatus)"
            if let key, let attributes = SecKeyCopyAttributes(key) as? [String: Any] {
                diagnostic += "; can sign: \(String(describing: attributes[kSecAttrCanSign as String]))"
            }
        }
        let policy = try await runner.run(
            "/usr/bin/security", ["find-identity", "-p", "codesigning", identity.keychainURL.path],
            timeout: 15, check: false)
        diagnostic += "\nGenerated fixture policy report (status \(policy.status)):\n"
        diagnostic += String(decoding: policy.stdout + policy.stderr, as: UTF8.self)
        return diagnostic
    }

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
        let certificateName = "LoadSide Test Identity \(UUID().uuidString)"
        try """
        [req]
        distinguished_name=dn
        x509_extensions=extensions
        prompt=no
        [dn]
        CN=\(certificateName)
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
        let originalP12 = try Data(contentsOf: p12)
        let before = try await keychainConfiguration(runner)
        XCTAssertEqual(findCertificate(certificateName), errSecItemNotFound)
        var identity: SigningIdentity? = try SigningIdentity(
            p12: p12, password: "fixture-password", workspace: directory, profiles: [profile])
        let keychainPath = try XCTUnwrap(identity?.keychainURL)
        XCTAssertEqual(identity?.name, certificateName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keychainPath.path))
        XCTAssertEqual(findCertificate(certificateName, in: try XCTUnwrap(identity?.keychain)), errSecSuccess)
        let binary = directory.appendingPathComponent("signed-echo")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: binary)
        let claims = directory.appendingPathComponent("entitlements.plist")
        let expectedClaims: [String: Any] = [
            "application-identifier": "NEWTEAM.com.example.fixture", "com.apple.developer.team-identifier": "NEWTEAM"
        ]
        try PropertyListSerialization.data(fromPropertyList: expectedClaims, format: .xml, options: 0).write(to: claims)
        let signing = try await runner.run(
            "/usr/bin/codesign",
            [
                "--force", "--sign", try XCTUnwrap(identity?.fingerprint), "--keychain", keychainPath.path, "--timestamp=none",
                "--generate-entitlement-der", "--entitlements", claims.path, binary.path
            ], timeout: 15, check: false)
        guard signing.status == 0 else {
            let diagnostic = try await fixtureIdentityDiagnostic(try XCTUnwrap(identity), runner: runner)
            throw LoadSideError("fixture.signing", "codesign failed (\(signing.status)): \(signing.diagnostic)\n\(diagnostic)")
        }
        _ = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", binary.path])
        let signedClaims = try await runner.run("/usr/bin/codesign", ["--display", "--entitlements", "-", "--xml", binary.path])
        XCTAssertEqual(
            try PropertyListSerialization.propertyList(from: signedClaims.stdout, format: nil) as? NSDictionary,
            expectedClaims as NSDictionary)
        let during = try await keychainConfiguration(runner)
        XCTAssertEqual(before, during, "Import must not change the user's default keychain or search list")
        XCTAssertEqual(findCertificate(certificateName), errSecItemNotFound, "The fixture certificate must stay in its private keychain")
        // The fingerprint's last read precedes an async subprocess. Keep its
        // keychain owner alive through signing, then test explicit destruction.
        withExtendedLifetime(identity) {}
        identity = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: keychainPath.path))
        let after = try await keychainConfiguration(runner)
        XCTAssertEqual(before, after)
        XCTAssertThrowsError(try SigningIdentity(p12: p12, password: "wrong-password", workspace: directory, profiles: [profile]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keychainPath.path))
        let afterWrongPassword = try await keychainConfiguration(runner)
        XCTAssertEqual(before, afterWrongPassword)
        XCTAssertThrowsError(
            try SigningIdentity(
                p12: p12, password: "fixture-password", workspace: directory, profiles: [testProfile(certificate: Data([0]))]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keychainPath.path))
        let afterMismatch = try await keychainConfiguration(runner)
        XCTAssertEqual(before, afterMismatch)
        XCTAssertEqual(findCertificate(certificateName), errSecItemNotFound)
        XCTAssertEqual(try Data(contentsOf: p12), originalP12, "Import and validation failures must never modify the source P12")
    }
}
