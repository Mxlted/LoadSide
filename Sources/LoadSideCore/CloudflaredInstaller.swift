import CryptoKit
import Darwin
import Foundation

/// Installs only the pinned official helper into private managed storage. The helper is
/// downloaded on demand; neither arbitrary PATH executables nor user-supplied tools are used.
public actor CloudflaredInstaller {
    public static let version = "2026.10.0"
    public nonisolated let directoryURL: URL
    private let release: Release
    private let macOSMajorVersion: Int
    private let downloader: @Sendable (URL, URL, Int64) async throws -> Void
    private var isInstalling = false
    private let fm = FileManager.default

    struct Release: Sendable {
        let archiveSHA256: String
        let executableSHA256: String
        let archiveBytes: Int64
        let executableBytes: Int64
        let minimumMacOSMajor: Int
        var archiveURL: URL {
            URL(
                string:
                    "https://github.com/cloudflare/cloudflared/releases/download/\(CloudflaredInstaller.version)/cloudflared-darwin-arm64.tgz"
            )!
        }

        static let pinned = Release(
            archiveSHA256: "a2f79ff7b9420aa537d74af239f376da170bbabeb529aec416002adac6a72e70",
            executableSHA256: "72edfd3eea463aef4d5cb89e2e209cecb048cc756c2b01915de2e0ad7cb39830",
            archiveBytes: 19_809_074, executableBytes: 39_364_384,
            // The official ARM64 executable declares LC_BUILD_VERSION minos 15.0.
            minimumMacOSMajor: 15)
    }

    public init(directory: URL? = nil) {
        directoryURL =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoadSide/Tools", isDirectory: true)
        release = .pinned
        macOSMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        downloader = Self.download
    }

    /// Fixture-only dependency injection keeps verification and cleanup tests offline.
    init(
        directory: URL, release: Release,
        macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        downloader: @escaping @Sendable (URL, URL, Int64) async throws -> Void
    ) {
        directoryURL = directory
        self.release = release
        self.macOSMajorVersion = macOSMajorVersion
        self.downloader = downloader
    }

    public func executable() async throws -> URL {
        try Task.checkCancellation()
        guard macOSMajorVersion >= release.minimumMacOSMajor else {
            throw Self.failure(
                "Automatic HTTPS requires macOS \(release.minimumMacOSMajor) or later for the pinned helper. Use Local downloads only or My HTTPS server on this Mac.",
                recovery: "Use Local downloads only or My HTTPS server, or update macOS.")
        }
        guard !isInstalling else { throw Self.failure("The HTTPS helper is already being prepared.") }
        isInstalling = true
        defer { isInstalling = false }
        try prepareDirectory()
        let installed = directoryURL.appendingPathComponent("cloudflared-\(Self.version)-arm64")
        if try exists(installed) {
            try verify(installed, bytes: release.executableBytes, digest: release.executableSHA256, executable: true)
            return installed
        }
        let staging = directoryURL.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("download.tgz")
        do { try await downloader(release.archiveURL, archive, release.archiveBytes) } catch is CancellationError {
            throw CancellationError()
        } catch let error as LoadSideError { throw error } catch {
            try Task.checkCancellation()
            throw Self.failure("The HTTPS helper could not be downloaded.", recovery: "Check your internet connection and try again.")
        }
        try Task.checkCancellation()
        try verify(archive, bytes: release.archiveBytes, digest: release.archiveSHA256)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let summary = try Archive.extract(
            archive, to: unpacked,
            limits: .init(
                maximumEntries: 1,
                maximumFileBytes: release.executableBytes, maximumExpandedBytes: release.executableBytes,
                maximumCompressionRatio: 20))
        guard summary.entries == 1, try fm.contentsOfDirectory(atPath: unpacked.path) == ["cloudflared"] else {
            throw Self.failure("The HTTPS helper archive contains unexpected files.")
        }
        let candidate = unpacked.appendingPathComponent("cloudflared")
        try verify(candidate, bytes: release.executableBytes, digest: release.executableSHA256, executable: true)
        try Task.checkCancellation()
        // RENAME_EXCL publishes a complete, verified executable atomically without replacing
        // another process's installation or any unexpected object at the destination.
        if renamex_np(candidate.path, installed.path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { throw Self.failure("The HTTPS helper could not be saved.") }
            try verify(installed, bytes: release.executableBytes, digest: release.executableSHA256, executable: true)
        }
        return installed
    }

    private func prepareDirectory() throws {
        guard directoryURL.isFileURL else { throw Self.failure("The HTTPS helper requires a local storage directory.") }
        let parent = directoryURL.deletingLastPathComponent()
        if !(try exists(parent)) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try verifyDirectory(parent)
        if !(try exists(directoryURL)) {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try verifyDirectory(directoryURL)
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure("The HTTPS helper storage directory is unsafe.") }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, 0o700) == 0 else { throw Self.failure("The HTTPS helper storage could not be made private.") }
    }

    private func verifyDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw Self.failure("The HTTPS helper storage must be a real directory owned by the current user.")
        }
    }

    private func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw Self.failure("The HTTPS helper storage could not be inspected.") }
        return false
    }

    private func verify(_ url: URL, bytes: Int64, digest: String, executable: Bool = false) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.failure("The saved HTTPS helper is missing or unsafe.") }
        defer { Darwin.close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
            initial.st_nlink == 1, initial.st_uid == getuid(), initial.st_size == bytes
        else {
            throw Self.failure("The HTTPS helper is not the expected private regular file.")
        }
        var hash = SHA256()
        var count: Int64 = 0
        // Reuse one bounded buffer for both archive and cached-executable verification;
        // hashing a large helper should not allocate a new Foundation Data for every read.
        var storage = [UInt8](repeating: 0, count: 64 * 1_024)
        try storage.withUnsafeMutableBytes { buffer in
            while true {
                try Task.checkCancellation()
                let length = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
                if length < 0, errno == EINTR { continue }
                guard length >= 0 else { throw Self.failure("The HTTPS helper could not be read for verification.") }
                if length == 0 { break }
                count += Int64(length)
                guard count <= bytes else { throw Self.failure("The HTTPS helper changed during verification.") }
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<length]))
            }
        }
        var final = stat()
        guard count == bytes, hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest,
            fstat(descriptor, &final) == 0, initial.st_size == final.st_size,
            initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec, initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
            initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec, initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
        else {
            throw Self.failure(
                "The HTTPS helper failed its integrity check.",
                recovery: "Remove the affected helper from LoadSide's managed Tools folder and try again.")
        }
        if executable, fchmod(descriptor, 0o700) != 0 { throw Self.failure("The HTTPS helper could not be made executable.") }
    }

    private static func download(_ source: URL, _ destination: URL, _ maximumBytes: Int64) async throws {
        guard allowedDownloadURL(source), maximumBytes > 0, maximumBytes <= 32 * 1_024 * 1_024 else {
            throw failure("The HTTPS helper download request is invalid.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("LoadSide", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: CloudflaredDownloadDelegate())
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            allowedDownloadURL(response.url), response.expectedContentLength <= maximumBytes
        else {
            throw failure("The HTTPS helper download returned an unexpected response.")
        }
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("The HTTPS helper download could not be staged privately.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var buffer = Data()
        var count: Int64 = 0
        buffer.reserveCapacity(64 * 1_024)
        for try await byte in bytes {
            count += 1
            guard count <= maximumBytes else { throw failure("The HTTPS helper download exceeded its size limit.") }
            buffer.append(byte)
            if buffer.count == 64 * 1_024 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.synchronize()
    }

    static func allowedDownloadURL(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
            url.port == nil || url.port == 443
        else { return false }
        return ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(
            url.host?.lowercased() ?? "")
    }

    private static func failure(_ message: String, recovery: String? = nil) -> LoadSideError {
        LoadSideError("https.helper", message, recovery: recovery ?? "Try setting up HTTPS again, or use a custom trusted HTTPS address.")
    }
}

private final class CloudflaredDownloadDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        CloudflaredInstaller.allowedDownloadURL(request.url) ? request : nil
    }
}
