import Foundation
import Security
import XCTest

@testable import LoadSideCore

private final class MemorySavedPasswords: SigningProfilePasswordStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    private var loads = 0
    var loadCount: Int { lock.withLock { loads } }
    var failSave = false
    func save(_ password: String, for id: UUID) throws {
        try lock.withLock {
            if failSave { throw LoadSideError("fixture.keychain", "Keychain fixture failure") }
            values[id] = password
        }
    }
    func load(for id: UUID) throws -> String? {
        lock.withLock {
            loads += 1
            return values[id]
        }
    }
    func delete(for id: UUID) throws { _ = lock.withLock { values.removeValue(forKey: id) } }
}
private final class SavedProfileExpiry: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var expired: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

final class SavedSigningProfilesTests: XCTestCase {
    private func inputs(_ root: URL) throws -> (URL, URL) {
        let certificate = root.appendingPathComponent("original-secret-name.p12")
        let profile = root.appendingPathComponent("original.mobileprovision")
        try Data("encrypted-p12-fixture".utf8).write(to: certificate)
        try Data("signed-profile-fixture".utf8).write(to: profile)
        return (certificate, profile)
    }
    private func store(_ root: URL, passwords: MemorySavedPasswords = .init(), expiry: SavedProfileExpiry = .init())
        -> SavedSigningProfileStore
    {
        SavedSigningProfileStore(
            directory: root.appendingPathComponent("saved"), passwords: passwords,
            profileInspector: { _ in
                if expiry.expired { throw LoadSideError("profile.expired", "Fixture profile expired") }
                return try testProfile()
            },
            certificateValidator: { _, password, _, _ in
                guard password == "fixture-password" else { throw LoadSideError("fixture.password", "Wrong fixture password") }
                return .distantFuture
            })
    }
    func testPrivateCopiesSurviveRemovalOfOriginalsAndNeverPersistPasswordInMetadata() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (certificate, profile) = try inputs(root)
        let store = store(root)
        let saved = try await store.save(name: "Work signing", certificate: certificate, password: "fixture-password", profiles: [profile])
        try FileManager.default.removeItem(at: certificate)
        try FileManager.default.removeItem(at: profile)
        let selected = try await store.select(saved.id)
        XCTAssertNotNil(selected)
        XCTAssertNil(selected?.password)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(selected?.certificate)), Data("encrypted-p12-fixture".utf8))
        let folder = root.appendingPathComponent("saved/" + saved.id.uuidString)
        let metadata = try String(contentsOf: folder.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertFalse(metadata.contains("fixture-password"))
        XCTAssertFalse(metadata.contains("original-secret-name"))
        for directory in [root.appendingPathComponent("saved"), folder] {
            XCTAssertEqual(
                (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
    func testRenameLastSelectionAndExplicitDeletionArePersisted() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (certificate, profile) = try inputs(root)
        let passwords = MemorySavedPasswords()
        let store = store(root, passwords: passwords)
        let saved = try await store.save(
            name: "Original", certificate: certificate, password: "fixture-password", profiles: [profile], rememberPassword: true)
        try await store.rename(saved.id, name: "Renamed")
        let restarted = self.store(root, passwords: passwords)
        let library = try await restarted.library()
        XCTAssertEqual(library.lastSelectedID, saved.id)
        XCTAssertEqual(library.profiles.first?.name, "Renamed")
        let selected = try await restarted.select(saved.id)
        XCTAssertEqual(selected?.password, "fixture-password")
        try await restarted.delete(saved.id)
        let after = try await restarted.library()
        XCTAssertTrue(after.profiles.isEmpty)
        XCTAssertNil(after.lastSelectedID)
        XCTAssertNil(try passwords.load(for: saved.id))
    }
    func testSelectionCanDeferPasswordAccessWithoutSkippingFileOrProfileValidation() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (certificate, profile) = try inputs(root)
        let passwords = MemorySavedPasswords()
        let expiry = SavedProfileExpiry()
        let store = store(root, passwords: passwords, expiry: expiry)
        let saved = try await store.save(
            name: "Restore without a prompt", certificate: certificate, password: "fixture-password", profiles: [profile],
            rememberPassword: true)
        _ = try await store.select(nil, loadPassword: false)

        let deferred = try await store.select(saved.id, loadPassword: false)
        XCTAssertEqual(deferred?.profile.id, saved.id)
        XCTAssertEqual(deferred?.profile.remembersPassword, true)
        XCTAssertNil(deferred?.password)
        XCTAssertNil(deferred?.passwordNotice, "An intentionally deferred load is not a missing-password error")
        XCTAssertEqual(passwords.loadCount, 0)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(deferred?.certificate)), Data("encrypted-p12-fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(deferred?.provisioningProfiles.first)), Data("signed-profile-fixture".utf8))
        let library = try await store.library()
        XCTAssertEqual(library.lastSelectedID, saved.id)

        let loaded = try await store.select(saved.id)
        XCTAssertEqual(loaded?.password, "fixture-password", "Default selection retains password retrieval")
        XCTAssertEqual(passwords.loadCount, 1)

        expiry.expired = true
        do {
            _ = try await store.select(saved.id, loadPassword: false)
            XCTFail("Expired profile was accepted")
        } catch { XCTAssertEqual((error as? LoadSideError)?.code, "profile.expired") }
        expiry.expired = false
        try Data("changed".utf8).write(to: XCTUnwrap(deferred?.certificate))
        do {
            _ = try await store.select(saved.id, loadPassword: false)
            XCTFail("Changed certificate was accepted")
        } catch { XCTAssertEqual((error as? LoadSideError)?.code, "savedProfile.corrupt") }
        XCTAssertEqual(passwords.loadCount, 1, "Deferred selection never calls password storage, including on failure")
    }
    func testCorruptAndMissingFilesAreReportedWithoutDeletingRecords() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (certificate, profile) = try inputs(root)
        let store = store(root)
        let saved = try await store.save(name: "Preserve me", certificate: certificate, password: "fixture-password", profiles: [profile])
        let directory = root.appendingPathComponent("saved/" + saved.id.uuidString)
        try Data("modified".utf8).write(to: directory.appendingPathComponent("identity.p12"))
        do {
            _ = try await store.select(saved.id)
            XCTFail("Changed certificate was accepted")
        } catch { XCTAssertEqual((error as? LoadSideError)?.code, "savedProfile.corrupt") }
        try Data("corrupt JSON".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        let library = try await store.library()
        XCTAssertEqual(library.profiles.count, 1)
        XCTAssertNotNil(library.profiles.first?.issue)
        XCTAssertFalse(library.issues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try await store.delete(saved.id)
        let after = try await store.library()
        XCTAssertTrue(after.profiles.isEmpty)
    }
    func testCorruptSelectionIndexDoesNotBlockExplicitDeletion() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (certificate, profile) = try inputs(root)
        let passwords = MemorySavedPasswords()
        let store = store(root, passwords: passwords)
        let saved = try await store.save(
            name: "Delete despite damaged index", certificate: certificate, password: "fixture-password", profiles: [profile],
            rememberPassword: true)
        let index = root.appendingPathComponent("saved/index.json")
        let damaged = Data("preserve damaged selection index".utf8)
        try damaged.write(to: index)
        try await store.delete(saved.id)
        XCTAssertNil(try passwords.load(for: saved.id))
        XCTAssertEqual(try Data(contentsOf: index), damaged)
        let library = try await store.library()
        XCTAssertTrue(library.profiles.isEmpty)
        XCTAssertNil(library.lastSelectedID)
        XCTAssertTrue(library.issues.contains { $0.contains("selection index is unreadable") })
    }
    func testProfileExpiryIsRecheckedWhenSelected() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (certificate, profile) = try inputs(root)
        let expiry = SavedProfileExpiry()
        let store = store(root, expiry: expiry)
        let saved = try await store.save(name: "Expires", certificate: certificate, password: "fixture-password", profiles: [profile])
        expiry.expired = true
        do {
            _ = try await store.select(saved.id)
            XCTFail("Expired profile was accepted")
        } catch { XCTAssertEqual((error as? LoadSideError)?.code, "profile.expired") }
        let library = try await store.library()
        XCTAssertEqual(library.profiles.count, 1)
    }
    func testInvalidPasswordOrKeychainFailureRollsBackCreation() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (certificate, profile) = try inputs(root)
        let passwords = MemorySavedPasswords()
        let store = store(root, passwords: passwords)
        do {
            _ = try await store.save(name: "Invalid", certificate: certificate, password: "wrong", profiles: [profile])
            XCTFail("Invalid password saved")
        } catch {}
        passwords.failSave = true
        do {
            _ = try await store.save(
                name: "Failed", certificate: certificate, password: "fixture-password", profiles: [profile], rememberPassword: true)
            XCTFail("Keychain failure ignored")
        } catch {}
        let library = try await store.library()
        XCTAssertTrue(library.profiles.isEmpty)
        XCTAssertTrue(library.issues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: certificate.path))
    }
    func testUnsafeManifestFilenameAndSymlinkSourcesAreRejected() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (certificate, profile) = try inputs(root)
        let store = store(root)
        let link = root.appendingPathComponent("link.p12")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: certificate)
        do {
            _ = try await store.save(name: "Unsafe", certificate: link, password: "fixture-password", profiles: [profile])
            XCTFail("Symlink source accepted")
        } catch {}
        let saved = try await store.save(name: "Safe", certificate: certificate, password: "fixture-password", profiles: [profile])
        let manifest = root.appendingPathComponent("saved/\(saved.id.uuidString)/manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var cert = try XCTUnwrap(json["certificate"] as? [String: Any])
        cert["name"] = "../../original-secret-name.p12"
        json["certificate"] = cert
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        do {
            _ = try await store.select(saved.id)
            XCTFail("Traversal manifest accepted")
        } catch { XCTAssertEqual((error as? LoadSideError)?.code, "savedProfile.corrupt") }
    }
    func testSystemKeychainGenericPasswordRoundTrip() throws {
        let service = "app.loadside.qa." + UUID().uuidString
        let keychain = SigningProfileKeychain(service: service)
        let otherService = SigningProfileKeychain(service: service + ".other")
        let id = UUID()
        let otherID = UUID()
        defer {
            try? keychain.delete(for: id)
            try? keychain.delete(for: otherID)
            try? otherService.delete(for: id)
        }
        let secret = UUID().uuidString
        try keychain.save(secret, for: id)
        try keychain.save("other-profile-fixture", for: otherID)
        try otherService.save("other-service-fixture", for: id)
        XCTAssertEqual(try keychain.load(for: id), secret)
        let reopened = SigningProfileKeychain(service: service)
        try reopened.save(secret + "-updated", for: id)
        XCTAssertEqual(try reopened.load(for: id), secret + "-updated")
        // Existing classic-keychain records keep their service/account schema and
        // update in place; no backend migration or duplicate record is introduced.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: false, kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let records = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?[kSecAttrService as String] as? String, service)
        XCTAssertEqual(records.first?[kSecAttrAccount as String] as? String, id.uuidString)
        try reopened.delete(for: id)
        XCTAssertNil(try keychain.load(for: id))
        XCTAssertEqual(try keychain.load(for: otherID), "other-profile-fixture")
        XCTAssertEqual(try otherService.load(for: id), "other-service-fixture")
    }
}

extension SavedSigningProfilesTests {
    func testGeneratedP12UsesRealValidationAndCleansDisposableIdentityKeychain() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("key.pem")
        let cert = root.appendingPathComponent("cert.pem")
        let der = root.appendingPathComponent("cert.der")
        let p12 = root.appendingPathComponent("identity.p12")
        let config = root.appendingPathComponent("openssl.cnf")
        let sourceProfile = root.appendingPathComponent("profile.mobileprovision")
        try """
        [req]
        distinguished_name=dn
        x509_extensions=extensions
        prompt=no
        [dn]
        CN=LoadSide Saved Profile Fixture
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
        _ = try await runner.run(
            "/usr/bin/openssl",
            ["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", p12.path, "-passout", "pass:public-fixture-password"])
        let fixtureCertificate = try Data(contentsOf: der)
        try Data("synthetic-profile-envelope".utf8).write(to: sourceProfile)
        let store = SavedSigningProfileStore(
            directory: root.appendingPathComponent("saved"), passwords: MemorySavedPasswords(),
            profileInspector: { _ in try testProfile(certificate: fixtureCertificate) })
        let before = try await runner.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        let saved = try await store.save(
            name: "Generated fixture", certificate: p12, password: "public-fixture-password", profiles: [sourceProfile])
        XCTAssertGreaterThan(saved.expiresAt, Date())
        let selected = try await store.select(saved.id)
        XCTAssertNotNil(selected?.certificate)
        XCTAssertNil(selected?.password)
        let allFiles = FileManager.default.enumerator(atPath: root.appendingPathComponent("saved").path)?.allObjects as? [String] ?? []
        XCTAssertFalse(allFiles.contains { $0.contains("keychain") || $0.contains("validation") })
        let after = try await runner.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        XCTAssertEqual(before.stdout, after.stdout)
    }
}
