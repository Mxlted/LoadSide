import CFileKeychain
import CryptoKit
import Darwin
import Foundation
import Security

public struct SavedSigningProfile: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public let profileCount: Int
    public let remembersPassword: Bool
    public let expiresAt: Date
    public var issue: String? = nil
}

public struct SavedSigningProfileLibrary: Sendable {
    public let profiles: [SavedSigningProfile]
    public let lastSelectedID: UUID?
    public let issues: [String]
}

public struct SavedSigningProfileSelection: Sendable {
    public let profile: SavedSigningProfile
    public let certificate: URL
    public let provisioningProfiles: [URL]
    public let password: String?
    public let passwordNotice: String?
}

public protocol SigningProfilePasswordStorage: Sendable {
    func save(_ password: String, for id: UUID) throws
    func load(for id: UUID) throws -> String?
    func delete(for id: UUID) throws
}

/// Only explicitly remembered passwords use this generic-password item. Signing identities never enter it.
public struct SigningProfileKeychain: SigningProfilePasswordStorage {
    private let service: String
    public init(service: String = "app.loadside.mac.saved-signing-password") { self.service = service }
    private func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: false
        ]
    }
    public func save(_ password: String, for id: UUID) throws {
        var values = query(id)
        values[kSecValueData as String] = Data(password.utf8)
        // The classic macOS keychain supports unsandboxed/ad-hoc evaluation builds. Its ACL
        // restricts access to this app; synchronizable=false prevents iCloud synchronization.
        // Do not claim ThisDeviceOnly semantics: that accessibility class belongs to the DP keychain.
        var access: SecAccess?
        try check(LSFileKeychainCreatePasswordAccess(&access))
        guard let access else { throw LoadSideError("savedProfile.keychainACL", "Could not create a private Keychain access policy.") }
        values[kSecAttrAccess as String] = access
        values[kSecAttrLabel as String] = "LoadSide saved signing password"
        let status = SecItemAdd(values as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: Data(password.utf8)] as CFDictionary))
        } else {
            try check(status)
        }
    }
    public func load(for id: UUID) throws -> String? {
        var values = query(id)
        values[kSecReturnData as String] = true
        values[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(values as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw LoadSideError(
                "savedProfile.keychainData", "The saved Keychain password is unreadable.",
                recovery: "Enter the password again, or save a new signing profile.")
        }
        return password
    }
    public func delete(for id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw LoadSideError(
                "savedProfile.keychain", "Keychain could not access the remembered password (status \(status)).",
                recovery: "Unlock your Keychain and allow LoadSide access, or save with Remember password turned off.")
        }
    }
}

/// The per-profile manifest is authoritative; the atomic index stores only the last selection.
/// A corrupt manifest is reported and preserved, never silently removed during enumeration.
public actor SavedSigningProfileStore {
    public typealias ProfileInspector = @Sendable (URL) throws -> ProvisioningProfile
    public typealias CertificateValidator = @Sendable (URL, String, [ProvisioningProfile], URL) throws -> Date
    private struct StoredFile: Codable {
        let name: String
        let sha256: String
    }
    private struct Manifest: Codable {
        let version: Int
        var profile: SavedSigningProfile
        let certificate: StoredFile
        let provisioningProfiles: [StoredFile]
        let certificateExpiresAt: Date
    }
    private struct Index: Codable {
        let version: Int
        var lastSelectedID: UUID?
    }
    private let root: URL
    private let passwords: any SigningProfilePasswordStorage
    private let inspectProfile: ProfileInspector
    private let validateCertificate: CertificateValidator
    private let fm = FileManager.default

    public init(
        directory: URL? = nil, passwords: any SigningProfilePasswordStorage = SigningProfileKeychain(),
        profileInspector: @escaping ProfileInspector = ProvisioningProfile.inspect,
        certificateValidator: @escaping CertificateValidator = SavedSigningProfileStore.validateIdentity
    ) {
        root =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
                "LoadSide/SigningProfiles", isDirectory: true)
        self.passwords = passwords
        inspectProfile = profileInspector
        validateCertificate = certificateValidator
    }

    public func library() throws -> SavedSigningProfileLibrary {
        try prepareRoot()
        var profiles: [SavedSigningProfile] = []
        var issues: [String] = []
        for folder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            guard let id = UUID(uuidString: folder.lastPathComponent), folder.lastPathComponent == id.uuidString else {
                if folder.lastPathComponent != "index.json" {
                    issues.append("An incomplete or unrecognized saved-profile item was preserved: \(folder.lastPathComponent)")
                }
                continue
            }
            do { profiles.append(try manifest(id).profile) } catch {
                let message = "Saved profile \(id.uuidString.prefix(8)) could not be read: \(error.localizedDescription)"
                issues.append(message)
                profiles.append(
                    SavedSigningProfile(
                        id: id, name: "Unreadable profile \(id.uuidString.prefix(8))", createdAt: .distantPast, profileCount: 0,
                        remembersPassword: false, expiresAt: .distantPast, issue: message))
            }
        }
        var selected: UUID?
        do { selected = try readIndex().lastSelectedID } catch {
            issues.append("The saved-profile selection index is unreadable. Stored signing files were preserved.")
        }
        if let selected, !profiles.contains(where: { $0.id == selected }) {
            issues.append("The last selected signing profile is missing or unreadable.")
        }
        return SavedSigningProfileLibrary(
            profiles: profiles.sorted { $0.createdAt > $1.createdAt }, lastSelectedID: selected, issues: issues)
    }

    public func save(name: String, certificate: URL, password: String, profiles: [URL], rememberPassword: Bool = false) throws
        -> SavedSigningProfile
    {
        try prepareRoot()
        let name = try validatedName(name)
        guard !profiles.isEmpty, profiles.count <= 128 else {
            throw LoadSideError("savedProfile.profiles", "Choose between 1 and 128 provisioning profiles to save.")
        }
        let id = UUID()
        let staging = root.appendingPathComponent(".pending-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false
        var passwordSaved = false
        defer {
            if !committed {
                try? fm.removeItem(at: staging)
                if passwordSaved { try? passwords.delete(for: id) }
            }
        }
        let copiedCertificate = staging.appendingPathComponent("identity.p12")
        let certificateData = try boundedFile(certificate)
        try privateWrite(certificateData, to: copiedCertificate)
        var storedProfiles: [StoredFile] = []
        var validatedProfiles: [ProvisioningProfile] = []
        for (index, source) in profiles.enumerated() {
            try Task.checkCancellation()
            let name = String(format: "profile-%03d.mobileprovision", index)
            let data = try boundedFile(source)
            let copied = staging.appendingPathComponent(name)
            try privateWrite(data, to: copied)
            let checked = try inspectProfile(copied)
            guard checked.distribution != "App Store" else {
                throw LoadSideError("savedProfile.distribution", "App Store profiles cannot be saved for direct IPA installation.")
            }
            validatedProfiles.append(checked)
            storedProfiles.append(StoredFile(name: name, sha256: hash(data)))
        }
        let validation = staging.appendingPathComponent("validation")
        try fm.createDirectory(at: validation, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let expiresAt: Date
        do { expiresAt = try validateCertificate(copiedCertificate, password, validatedProfiles, validation) } catch {
            try? fm.removeItem(at: validation)
            throw error
        }
        try fm.removeItem(at: validation)
        let record = SavedSigningProfile(
            id: id, name: name, createdAt: Date(), profileCount: profiles.count, remembersPassword: rememberPassword,
            expiresAt: min(expiresAt, validatedProfiles.map(\.expiresAt).min() ?? expiresAt))
        let manifest = Manifest(
            version: 1, profile: record, certificate: StoredFile(name: "identity.p12", sha256: hash(certificateData)),
            provisioningProfiles: storedProfiles, certificateExpiresAt: expiresAt)
        try privateWrite(JSONEncoder().encode(manifest), to: staging.appendingPathComponent("manifest.json"))
        if rememberPassword {
            try passwords.save(password, for: id)
            passwordSaved = true
        }
        let destination = directory(id)
        try fm.moveItem(at: staging, to: destination)
        do { try writeIndex(Index(version: 1, lastSelectedID: id)) } catch {
            try? fm.moveItem(at: destination, to: staging)
            throw error
        }
        committed = true
        return record
    }

    /// Selection always validates managed files and current profile validity.
    /// Set loadPassword to false for browsing or startup restoration, deferring
    /// any Keychain authorization prompt until the user starts signing.
    public func select(_ id: UUID?, loadPassword: Bool = true) throws -> SavedSigningProfileSelection? {
        try prepareRoot()
        guard let id else {
            try writeIndex(Index(version: 1, lastSelectedID: nil))
            return nil
        }
        let record = try manifest(id)
        let certificate = directory(id).appendingPathComponent(record.certificate.name)
        guard hash(try boundedFile(certificate)) == record.certificate.sha256 else {
            throw corrupt("The saved certificate copy has changed or is damaged.")
        }
        guard record.certificateExpiresAt > Date() else {
            throw LoadSideError(
                "savedProfile.expired", "This saved signing certificate has expired.",
                recovery: "Save a new signing profile using a current certificate and provisioning profiles.")
        }
        var profiles: [URL] = []
        for stored in record.provisioningProfiles {
            let url = directory(id).appendingPathComponent(stored.name)
            guard hash(try boundedFile(url)) == stored.sha256 else {
                throw corrupt("A saved provisioning profile has changed or is damaged.")
            }
            _ = try inspectProfile(url)  // verifies signature, structure, and current expiry each selection
            profiles.append(url)
        }
        var password: String?
        var passwordNotice: String?
        if loadPassword && record.profile.remembersPassword {
            do {
                password = try passwords.load(for: id)
                if password == nil { passwordNotice = "The remembered password is missing from Keychain. Enter it again to sign." }
            } catch { passwordNotice = "The saved files are ready, but Keychain could not provide the password. Enter it again to sign." }
        }
        try writeIndex(Index(version: 1, lastSelectedID: id))
        return SavedSigningProfileSelection(
            profile: record.profile, certificate: certificate, provisioningProfiles: profiles, password: password,
            passwordNotice: passwordNotice)
    }

    public func rename(_ id: UUID, name: String) throws {
        var stored = try manifest(id)
        stored.profile.name = try validatedName(name)
        try privateWrite(JSONEncoder().encode(stored), to: directory(id).appendingPathComponent("manifest.json"), replacing: true)
    }

    public func delete(_ id: UUID) throws {
        try prepareRoot()
        let source = directory(id)
        // Corrupt manifests may still be deleted explicitly by their safe UUID identity.
        try verifyDirectory(source)
        // The index is only selection state. Keep a damaged index intact for recovery,
        // while still allowing explicit deletion of a profile and its Keychain password.
        let oldIndex = try? readIndex()
        let tombstone = root.appendingPathComponent(".deleting-\(id.uuidString)")
        guard !fm.fileExists(atPath: tombstone.path) else {
            throw corrupt("A previous deletion is incomplete; saved files were preserved.")
        }
        try fm.moveItem(at: source, to: tombstone)
        do {
            if oldIndex?.lastSelectedID == id { try writeIndex(Index(version: 1, lastSelectedID: nil)) }
            try passwords.delete(for: id)
        } catch {
            try? fm.moveItem(at: tombstone, to: source)
            if let oldIndex { try? writeIndex(oldIndex) }
            throw error
        }
        do { try fm.removeItem(at: tombstone) } catch {
            throw LoadSideError(
                "savedProfile.cleanup", "The signing profile was removed from use, but its private files could not be deleted.",
                recovery: "Check disk permissions. The incomplete deletion remains visible in saved-profile diagnostics.")
        }
    }

    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func validatedName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw LoadSideError("savedProfile.name", "Use a signing-profile name between 1 and 80 characters without control characters.")
        }
        return value
    }
    private func manifest(_ id: UUID) throws -> Manifest {
        try verifyDirectory(directory(id))
        let data = try boundedFile(directory(id).appendingPathComponent("manifest.json"), maximum: 256 * 1_024)
        let value = try JSONDecoder().decode(Manifest.self, from: data)
        guard value.version == 1, value.profile.id == id, value.certificate.name == "identity.p12",
            !value.provisioningProfiles.isEmpty, value.provisioningProfiles.count <= 128,
            value.profile.profileCount == value.provisioningProfiles.count,
            Set(value.provisioningProfiles.map(\.name)).count == value.provisioningProfiles.count,
            value.provisioningProfiles.enumerated().allSatisfy({
                $0.element.name == String(format: "profile-%03d.mobileprovision", $0.offset)
            })
        else { throw corrupt("The saved signing-profile manifest is invalid.") }
        _ = try validatedName(value.profile.name)
        return value
    }
    private func prepareRoot() throws {
        let parent = root.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try verifyDirectory(parent)
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try verifyDirectory(root)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    private func verifyDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw corrupt("The saved-profile directory is missing or unsafe.")
        }
    }
    private func boundedFile(_ url: URL, maximum: Int = 16 * 1_024 * 1_024) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0,
            size <= maximum
        else { throw corrupt("A signing-profile file is missing, unsafe, empty, or too large.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw corrupt("A signing-profile file exceeds its size limit.") }
        return data
    }
    private func readIndex() throws -> Index {
        let url = root.appendingPathComponent("index.json")
        guard fm.fileExists(atPath: url.path) else { return Index(version: 1, lastSelectedID: nil) }
        let index = try JSONDecoder().decode(Index.self, from: boundedFile(url, maximum: 16 * 1_024))
        guard index.version == 1 else { throw corrupt("Unsupported saved-profile index version.") }
        return index
    }
    private func writeIndex(_ index: Index) throws {
        try privateWrite(JSONEncoder().encode(index), to: root.appendingPathComponent("index.json"), replacing: true)
    }
    private func privateWrite(_ data: Data, to target: URL, replacing: Bool = false) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LoadSideError("savedProfile.write", "Could not create a private signing-profile file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? fm.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        if replacing {
            guard Darwin.rename(temporary.path, target.path) == 0 else {
                throw LoadSideError("savedProfile.write", "Could not atomically update the signing-profile record.")
            }
        } else {
            try fm.moveItem(at: temporary, to: target)
        }
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func corrupt(_ message: String) -> LoadSideError {
        LoadSideError(
            "savedProfile.corrupt", message,
            recovery:
                "The saved material was preserved. Restore its files from a trusted backup or explicitly delete this profile and import it again."
        )
    }

    public nonisolated static func validateIdentity(_ p12: URL, _ password: String, _ profiles: [ProvisioningProfile], _ workspace: URL)
        throws -> Date
    {
        let identity = try SigningIdentity(p12: p12, password: password, workspace: workspace, profiles: profiles)
        guard let certificate = SecCertificateCreateWithData(nil, identity.certificate as CFData),
            let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
            let property = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any]
        else { throw LoadSideError("savedProfile.certificate", "Could not read the certificate expiration date.") }
        if let date = property[kSecPropertyKeyValue as String] as? Date { return date }
        if let seconds = property[kSecPropertyKeyValue as String] as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
        }
        throw LoadSideError("savedProfile.certificate", "The certificate expiration date is invalid.")
    }
}
