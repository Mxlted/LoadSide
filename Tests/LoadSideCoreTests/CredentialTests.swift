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

    private func verifyImportedPrivateKey(_ identity: SigningIdentity) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchSearchList as String: [identity.keychain],
            kSecUseDataProtectionKeychain as String: false,
            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let reference = try XCTUnwrap(result) as! SecIdentity
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(reference, &key), errSecSuccess)
        let privateKey = try XCTUnwrap(key)
        var importedCertificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(reference, &importedCertificate), errSecSuccess)
        XCTAssertEqual(SecCertificateCopyData(try XCTUnwrap(importedCertificate)) as Data, identity.certificate)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, identity.certificate as CFData))
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        XCTAssertTrue(SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm))
        XCTAssertTrue(SecKeyIsAlgorithmSupported(publicKey, .verify, algorithm))
        let challenge = Data("LoadSide disposable signing identity challenge".utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, algorithm, challenge as CFData, nil))
        XCTAssertTrue(SecKeyVerifySignature(publicKey, algorithm, challenge as CFData, signature, nil))
        let alteredChallenge = challenge + Data([0])
        XCTAssertFalse(SecKeyVerifySignature(publicKey, algorithm, alteredChallenge as CFData, signature, nil))
    }

    /// Synthetic identity tests import, caller key access, crypto, and cleanup.
    /// External codesign trust/access and iOS installation require a real trusted identity.
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
        try verifyImportedPrivateKey(try XCTUnwrap(identity))
        let during = try await keychainConfiguration(runner)
        XCTAssertEqual(before, during, "Import must not change the user's default keychain or search list")
        XCTAssertEqual(findCertificate(certificateName), errSecItemNotFound, "The fixture certificate must stay in its private keychain")
        // Retain the owner through the async configuration check, then verify
        // explicit destruction after the helper has released its key references.
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
