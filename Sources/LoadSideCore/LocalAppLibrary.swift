import Foundation
import CryptoKit
import Darwin

/// A private copy of an engine-verified signing output. Device installation remains unverified.
public struct LocalAppRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public let bundleIdentifier: String
    public let bundleVersion: String?
    public let sha256: String
    public let byteCount: Int64
    public let createdAt: Date
    public var supportsInstallation: Bool { bundleVersion != nil }
}

public struct LocalAppCatalog: Sendable {
    public let apps: [LocalAppRecord]
    public let issues: [String]
}

/// Stores only copies explicitly added from successful signing results. Credentials and arbitrary
/// directories are never published. Each record is immutable and lives at a generated UUID path.
public actor LocalAppLibrary {
    public nonisolated let directoryURL: URL
    private let fm = FileManager.default
    static let maximumIPABytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    private struct Manifest: Codable { let version: Int; let app: LocalAppRecord }

    public init(directory: URL? = nil) {
        directoryURL = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoadSide/Apps", isDirectory: true)
    }

    public func library() throws -> LocalAppCatalog {
        try prepareRoot()
        var apps: [LocalAppRecord] = [], issues: [String] = []
        let entries = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        guard entries.count <= 2_000 else { throw failure("The app library has too many entries to enumerate safely.") }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: entry.lastPathComponent), id.uuidString == entry.lastPathComponent else {
                issues.append("An incomplete or unrecognized library entry was preserved.")
                continue
            }
            do {
                let record = try readRecord(id)
                let file = try openArchive(id)
                defer { Darwin.close(file) }
                let info = try information(file)
                guard info.st_size == record.byteCount else { throw failure("The saved IPA size changed.") }
                apps.append(record)
            } catch { issues.append("App \(id.uuidString.prefix(8)) is unavailable: \(error.localizedDescription)") }
        }
        return LocalAppCatalog(apps: apps.sorted { $0.createdAt > $1.createdAt }, issues: issues)
    }

    /// The result must come from the signing engine. SHA-256 binds the private copy to that exact
    /// verified output; an edited or replaced export is refused. Legacy records without a known
    /// CFBundleVersion are download-only rather than inventing an installation manifest version.
    @discardableResult
    public func add(_ result: SigningResult, bundleVersion: String? = nil) throws -> LocalAppRecord {
        try prepareRoot()
        guard result.signedCodeCount > 0, !result.certificateName.isEmpty, !result.teamIdentifier.isEmpty else {
            throw failure("Only successfully signed and verified outputs can enter the app library.")
        }
        let version = bundleVersion ?? result.bundleVersion
        try validateMetadata(name: result.displayName, identifier: result.bundleIdentifier, version: version, hash: result.sha256)
        guard try fm.contentsOfDirectory(atPath: directoryURL.path).count < 1_000 else { throw failure("The library is full. Remove an app before adding another.") }
        let source = try openRegular(result.output)
        defer { Darwin.close(source) }
        let original = try information(source)
        guard original.st_size > 0, original.st_size <= Self.maximumIPABytes else { throw failure("The IPA is empty or larger than the 8 GiB library limit.") }
        let id = UUID(), staging = directoryURL.appendingPathComponent(".pending-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false
        defer { if !committed { try? fm.removeItem(at: staging) } }
        let output = staging.appendingPathComponent("app.ipa")
        let destination = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else { throw failure("Could not create a private library copy.") }
        let reader = FileHandle(fileDescriptor: source, closeOnDealloc: false)
        let writer = FileHandle(fileDescriptor: destination, closeOnDealloc: true)
        defer { try? writer.close() }
        var hasher = SHA256(), copied: Int64 = 0
        while let block = try reader.read(upToCount: 1_024 * 1_024), !block.isEmpty {
            try Task.checkCancellation()
            copied += Int64(block.count)
            guard copied <= original.st_size else { throw failure("The IPA changed while it was being copied.") }
            hasher.update(data: block)
            try writer.write(contentsOf: block)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard copied == original.st_size, digest == result.sha256.lowercased(), unchanged(original, try information(source)) else {
            throw failure("The exported IPA no longer matches its verified signing result.")
        }
        try writer.synchronize(); try writer.close()
        let record = LocalAppRecord(id: id, displayName: result.displayName, bundleIdentifier: result.bundleIdentifier,
                                    bundleVersion: version, sha256: digest, byteCount: copied, createdAt: result.completedAt)
        let metadata = try JSONEncoder().encode(Manifest(version: 1, app: record))
        let manifestPath = staging.appendingPathComponent("manifest.json")
        let manifestFD = Darwin.open(manifestPath.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard manifestFD >= 0 else { throw failure("Could not create the app library record.") }
        let manifestHandle = FileHandle(fileDescriptor: manifestFD, closeOnDealloc: true)
        defer { try? manifestHandle.close() }
        try manifestHandle.write(contentsOf: metadata); try manifestHandle.synchronize(); try manifestHandle.close()
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: directoryURL.appendingPathComponent(id.uuidString))
        committed = true
        return record
    }

    /// Removes only the managed UUID directory, never the user's original export.
    public func remove(_ id: UUID) throws {
        try prepareRoot()
        let directory = directoryURL.appendingPathComponent(id.uuidString)
        try verifyDirectory(directory)
        try fm.removeItem(at: directory)
    }

    func record(_ id: UUID) throws -> LocalAppRecord { try prepareRoot(); return try readRecord(id) }

    /// Opens without following links, verifies the content hash, then returns that same descriptor
    /// for streaming. Replacing the pathname cannot redirect an in-progress download.
    func download(_ id: UUID) throws -> LocalAppDownload {
        try prepareRoot()
        let record = try readRecord(id), descriptor = try openArchive(id)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let initial = try information(descriptor)
            guard initial.st_size == record.byteCount else { throw failure("The saved IPA size changed.") }
            var hash = SHA256(), readBytes: Int64 = 0
            while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
                try Task.checkCancellation()
                readBytes += Int64(data.count)
                guard readBytes <= record.byteCount else { throw failure("The saved IPA changed during its integrity check.") }
                hash.update(data: data)
            }
            guard readBytes == record.byteCount, hash.finalize().map({ String(format: "%02x", $0) }).joined() == record.sha256,
                  unchanged(initial, try information(descriptor)) else { throw failure("The saved IPA failed its integrity check.") }
            try handle.seek(toOffset: 0)
            return LocalAppDownload(record: record, handle: handle)
        } catch { try? handle.close(); throw error }
    }

    private func readRecord(_ id: UUID) throws -> LocalAppRecord {
        let descriptor = try openManagedFile(id, name: "manifest.json")
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let info = try information(descriptor)
        guard info.st_size > 0, info.st_size <= 64 * 1_024 else { throw failure("The library record is too large or empty.") }
        let data = try handle.read(upToCount: 64 * 1_024 + 1) ?? Data()
        guard data.count <= 64 * 1_024 else { throw failure("The library record is too large.") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data), app = manifest.app
        guard manifest.version == 1, app.id == id, app.byteCount > 0, app.byteCount <= Self.maximumIPABytes else { throw failure("The library record is invalid.") }
        try validateMetadata(name: app.displayName, identifier: app.bundleIdentifier, version: app.bundleVersion, hash: app.sha256)
        return app
    }

    private func validateMetadata(name: String, identifier: String, version: String?, hash: String) throws {
        guard !name.isEmpty, name.utf8.count <= 1_024, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw failure("The app library metadata is invalid.") }
        try SigningPreflight.validateIdentifier(identifier)
        if let version {
            guard !version.isEmpty, version.utf8.count <= 128,
                  !version.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw failure("The app's bundle version is invalid.") }
        }
    }

    private func prepareRoot() throws {
        guard directoryURL.isFileURL else { throw failure("The library must be a local directory.") }
        let parent = directoryURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) { try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try verifyDirectory(parent)
        if !fm.fileExists(atPath: directoryURL.path) { try fm.createDirectory(at: directoryURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try verifyDirectory(directoryURL)
        // The root is user-owned; private permissions prevent other local users editing its catalog.
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("The app library directory is unsafe.") }
        defer { Darwin.close(descriptor) }
        guard try information(descriptor).st_uid == getuid(), fchmod(descriptor, 0o700) == 0 else { throw failure("The app library must be owned by the current user.") }
    }

    private func verifyDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw failure("An app library directory is missing or is a symbolic link.") }
    }

    private func openArchive(_ id: UUID) throws -> Int32 { try openManagedFile(id, name: "app.ipa") }
    private func openManagedFile(_ id: UUID, name: String) throws -> Int32 {
        let root = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw failure("The app library directory is unsafe.") }
        defer { Darwin.close(root) }
        let folder = openat(root, id.uuidString, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw failure("The app library entry is missing or unsafe.") }
        defer { Darwin.close(folder) }
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("A saved app file is missing or unsafe.") }
        do {
            let info = try information(descriptor)
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid() else { throw failure("A saved app file is not a private regular file.") }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
    private func openRegular(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw failure("The IPA must be a local file.") }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("The IPA is missing or is not a regular file.") }
        do {
            guard try information(descriptor).st_mode & S_IFMT == S_IFREG else { throw failure("The IPA must be a regular file.") }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
    private func information(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure("Could not inspect a library file.") }
        return info
    }
    private func unchanged(_ first: stat, _ second: stat) -> Bool {
        first.st_size == second.st_size && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec &&
            first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec &&
            first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
    private func failure(_ message: String) -> LoadSideError { LoadSideError("library.invalid", message, recovery: "Add a fresh verified signing output, or remove the affected library copy. Original exports are preserved.") }
}

struct LocalAppDownload: Sendable {
    let record: LocalAppRecord
    let handle: FileHandle
}
