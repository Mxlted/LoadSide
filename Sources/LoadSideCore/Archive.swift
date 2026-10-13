import CArchive
import Darwin
import Foundation

/// Streaming extraction and export. Archive metadata is never allowed to create an arbitrary filesystem object.
public enum Archive {
    public struct Limits: Sendable {
        public var maximumEntries: Int
        public var maximumFileBytes: Int64
        public var maximumExpandedBytes: Int64
        public var maximumCompressionRatio: Int64
        public init(
            maximumEntries: Int = 100_000, maximumFileBytes: Int64 = 4 * 1_024 * 1_024 * 1_024,
            maximumExpandedBytes: Int64 = 16 * 1_024 * 1_024 * 1_024, maximumCompressionRatio: Int64 = 1_000
        ) {
            self.maximumEntries = maximumEntries
            self.maximumFileBytes = maximumFileBytes
            self.maximumExpandedBytes = maximumExpandedBytes
            self.maximumCompressionRatio = maximumCompressionRatio
        }
    }

    public struct ExtractionSummary: Sendable {
        public let entries: Int
        public let expandedBytes: Int64
    }

    @discardableResult public static func extract(_ source: URL, to destination: URL, limits: Limits = .init()) throws -> ExtractionSummary
    {
        let fm = FileManager.default
        guard limits.maximumEntries > 0, limits.maximumFileBytes > 0, limits.maximumExpandedBytes > 0, limits.maximumCompressionRatio > 0
        else {
            throw LoadSideError("archive.limits", "Archive limits must be positive.")
        }
        guard source.isFileURL, try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LoadSideError("archive.source", "Archive input must be a regular local file.")
        }
        let requestedRoot = destination.standardizedFileURL
        let root = requestedRoot.resolvingSymlinksInPath()
        if (try? requestedRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw LoadSideError("archive.destination", "Extraction requires a real directory, not a symbolic link.")
        }
        if fm.fileExists(atPath: root.path) {
            guard try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                try fm.contentsOfDirectory(atPath: root.path).isEmpty
            else {
                throw LoadSideError("archive.destination", "Extraction requires an empty, real directory.")
            }
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        guard let reader = archive_read_new() else { throw LoadSideError("archive.memory", "Unable to allocate archive reader.") }
        defer { archive_read_free(reader) }
        try enableBuiltInFilter(reader, source: source)
        archive_read_support_format_zip(reader)
        archive_read_support_format_tar(reader)
        archive_read_support_format_ar(reader)
        guard archive_read_open_filename(reader, source.path, 64 * 1024) == ARCHIVE_OK else { throw failure(reader, "open") }
        let compressed = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var entry: OpaquePointer?
        var names = Set<String>()
        var entries = 0
        var total: Int64 = 0
        var links: [(URL, String)] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK, let entry else { throw failure(reader, "read header") }
            entries += 1
            guard entries <= limits.maximumEntries else { throw limit("entry count") }
            guard archive_entry_is_encrypted(entry) <= 0 else {
                throw LoadSideError("archive.encrypted", "Password-protected archives are unsupported.")
            }
            guard let raw = archive_entry_pathname(entry), let rawName = String(validatingCString: raw) else {
                throw LoadSideError("archive.path", "Archive contains an invalid UTF-8 path.")
            }
            let name = try safePath(rawName)
            if name.isEmpty { continue }
            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(key).inserted else {
                throw LoadSideError("archive.duplicate", "Archive contains a duplicate or case-colliding path: \(name)")
            }
            let target = root.appendingPathComponent(name)
            try ensureParents(of: target, root: root)
            guard archive_entry_hardlink(entry) == nil else {
                throw LoadSideError("archive.hardlink", "Archive hard links are unsupported: \(name)")
            }
            let type = archive_entry_filetype(entry)
            if type == mode_t(0o040000) {
                if fm.fileExists(atPath: target.path) {
                    guard try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                        try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
                    else {
                        throw LoadSideError("archive.collision", "Archive directory conflicts with another entry: \(name)")
                    }
                } else {
                    try fm.createDirectory(at: target, withIntermediateDirectories: false)
                }
                continue
            }
            guard !fm.fileExists(atPath: target.path) else {
                throw LoadSideError("archive.collision", "Archive entry conflicts with a directory: \(name)")
            }
            if type == mode_t(0o120000) {
                guard let rawLink = archive_entry_symlink(entry), let link = String(validatingCString: rawLink) else {
                    throw LoadSideError("archive.symlink", "Invalid symbolic link: \(name)")
                }
                try validateLink(link, from: target, root: root)
                links.append((target, link))
                continue
            }
            guard type == mode_t(0o100000) else {
                throw LoadSideError("archive.filetype", "Archive contains an unsupported special file: \(name)")
            }
            let declared = archive_entry_size(entry)
            guard declared >= 0, declared <= limits.maximumFileBytes else { throw limit("individual file size") }
            guard declared <= limits.maximumExpandedBytes - total else { throw limit("expanded size") }
            guard
                fm.createFile(
                    atPath: target.path, contents: nil,
                    attributes: [.posixPermissions: archive_entry_perm(entry) & 0o111 == 0 ? 0o644 : 0o755])
            else {
                throw LoadSideError("archive.write", "Unable to create extracted file: \(name)")
            }
            let handle = try FileHandle(forWritingTo: target)
            do {
                var written: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let count = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                    guard count >= 0 else { throw failure(reader, "read content") }
                    if count == 0 { break }
                    written += Int64(count)
                    total += Int64(count)
                    guard written <= limits.maximumFileBytes, total <= limits.maximumExpandedBytes else { throw limit("expanded size") }
                    // A floor permits legitimate highly compressible metadata without permitting unbounded expansion.
                    if total > 100 * 1_024 * 1_024, compressed > 0, total / compressed > limits.maximumCompressionRatio {
                        throw limit("compression ratio")
                    }
                    try handle.write(contentsOf: Data(buffer.prefix(count)))
                }
                guard written == declared else {
                    throw LoadSideError("archive.size", "Archive entry size does not match its content: \(name)")
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        }
        // Delaying links prevents subsequent archive entries from writing through them.
        for (target, link) in links {
            try Task.checkCancellation()
            try ensureParents(of: target, root: root)
            guard !fm.fileExists(atPath: target.path) else {
                throw LoadSideError("archive.collision", "Symbolic link conflicts with another entry.")
            }
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
        }
        for (target, _) in links {
            let resolved = try physicalPath(target)
            guard resolved.hasPrefix(try physicalPath(root) + "/"), fm.fileExists(atPath: target.path) else {
                throw LoadSideError(
                    "archive.symlink", "Archive contains a dangling, cyclic, or escaping symbolic link: \(target.lastPathComponent)")
            }
        }
        return ExtractionSummary(entries: entries, expandedBytes: total)
    }

    public static func createIPA(from directory: URL, to output: URL) throws {
        let fm = FileManager.default
        let root = directory.standardizedFileURL
        let rootPhysical = try physicalPath(root)
        let outputPhysical = try physicalPath(output.deletingLastPathComponent()) + "/" + output.lastPathComponent
        guard !outputPhysical.hasPrefix(rootPhysical + "/") else {
            throw LoadSideError("archive.output", "The output archive must be outside its source directory.")
        }
        guard !fm.fileExists(atPath: output.path) else { throw LoadSideError("archive.outputExists", "The output file already exists.") }
        guard let writer = archive_write_new() else { throw LoadSideError("archive.memory", "Unable to allocate ZIP writer.") }
        // O_EXCL also closes the check/create race; private permissions apply from the first byte.
        let descriptor = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            archive_write_free(writer)
            throw LoadSideError("archive.output", "Unable to create a new private output archive: \(String(cString: strerror(errno)))")
        }
        var succeeded = false
        defer {
            archive_write_free(writer)
            Darwin.close(descriptor)
            if !succeeded { try? fm.removeItem(at: output) }
        }
        archive_write_set_format_zip(writer)
        guard archive_write_open_fd(writer, descriptor) == ARCHIVE_OK else { throw failure(writer, "open export") }
        var enumerationError: Error?
        guard
            let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: nil,
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                })
        else {
            throw LoadSideError("archive.enumerate", "Unable to enumerate export contents.")
        }
        // Enumerated URLs may canonicalize /var to /private/var. The enumeration
        // depth identifies relative components without subtracting filesystem aliases.
        var names: [String] = []
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            names.append(file.pathComponents.suffix(enumerator.level).joined(separator: "/"))
        }
        if let enumerationError { throw enumerationError }
        for name in names.sorted() {
            let file = root.appendingPathComponent(name)
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            _ = try safePath(name)
            guard let entry = archive_entry_new() else { throw LoadSideError("archive.memory", "Unable to allocate ZIP entry.") }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, name)
            let permissions = (try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            archive_entry_set_perm(entry, mode_t(permissions & 0o111 == 0 ? 0o644 : 0o755))
            if values.isSymbolicLink == true {
                let link = try fm.destinationOfSymbolicLink(atPath: file.path)
                try validateLink(link, from: file, root: root)
                let resolved = try physicalPath(file)
                guard resolved.hasPrefix(rootPhysical + "/"), fm.fileExists(atPath: file.path) else {
                    throw LoadSideError("archive.symlink", "Unsafe export symbolic link: \(name)")
                }
                archive_entry_set_filetype(entry, UInt32(0o120000))
                archive_entry_set_symlink(entry, link)
                archive_entry_set_size(entry, 0)
            } else if values.isDirectory == true {
                archive_entry_set_filetype(entry, UInt32(0o040000))
                archive_entry_set_perm(entry, 0o755)
                archive_entry_set_size(entry, 0)
            } else if values.isRegularFile == true {
                archive_entry_set_filetype(entry, UInt32(0o100000))
                archive_entry_set_size(entry, Int64(values.fileSize ?? 0))
            } else {
                throw LoadSideError("archive.filetype", "Unsupported export file type: \(name)")
            }
            guard archive_write_header(writer, entry) == ARCHIVE_OK else { throw failure(writer, "write header") }
            if values.isRegularFile == true && values.isSymbolicLink != true {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    let count = data.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
                    guard count == data.count else { throw failure(writer, "write content") }
                }
            }
            guard archive_write_finish_entry(writer) == ARCHIVE_OK else { throw failure(writer, "finish entry") }
        }
        guard archive_write_close(writer) == ARCHIVE_OK else { throw failure(writer, "close export") }
        succeeded = true
    }

    private static func physicalPath(_ url: URL) throws -> String {
        guard let resolved = Darwin.realpath(url.path, nil) else {
            throw LoadSideError("archive.path", "Unable to resolve filesystem path: \(url.lastPathComponent)")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Never register a filter that can fall back to executing a decompression helper.
    private static func enableBuiltInFilter(_ reader: OpaquePointer, source: URL) throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let prefix = Array(try handle.read(upToCount: 16) ?? Data())
        let status: Int32
        let name: String
        if prefix.starts(with: [0x1f, 0x8b]) {
            name = "gzip"
            status = archive_read_support_filter_gzip(reader)
        } else if prefix.starts(with: [0x42, 0x5a, 0x68]) {
            name = "bzip2"
            status = archive_read_support_filter_bzip2(reader)
        } else if prefix.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) {
            name = "xz"
            status = archive_read_support_filter_xz(reader)
        } else if prefix.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) {
            name = "zstd"
            status = archive_read_support_filter_zstd(reader)
        } else if source.pathExtension.lowercased() == "lzma" {
            name = "lzma"
            status = archive_read_support_filter_lzma(reader)
        } else {
            name = "uncompressed"
            status = archive_read_support_filter_none(reader)
        }
        // ARCHIVE_WARN can mean an external program bidder was registered. Free the reader before opening it.
        guard status == ARCHIVE_OK else {
            throw LoadSideError(
                "archive.filter", "This macOS installation lacks built-in \(name) decompression support.",
                recovery:
                    "Repackage the archive using ZIP or a supported built-in compression format. External decompression programs are never executed."
            )
        }
    }

    static func safePath(_ raw: String) throws -> String {
        guard !raw.hasPrefix("/"), !raw.contains("\\"), !raw.contains(":"), !raw.utf8.contains(0), raw.utf8.count <= 4096 else {
            throw LoadSideError("archive.path", "Archive contains an unsafe path: \(raw)")
        }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(".."), parts.allSatisfy({ $0.utf8.count <= 255 }) else {
            throw LoadSideError("archive.traversal", "Archive path traversal was rejected: \(raw)")
        }
        return parts.filter { $0 != "." }.joined(separator: "/")
    }
    private static func ensureParents(of file: URL, root: URL) throws {
        let parent = file.deletingLastPathComponent()
        guard parent.path == root.path || parent.path.hasPrefix(root.path + "/") else {
            throw LoadSideError("archive.traversal", "Archive entry escaped its workspace.")
        }
        let components = parent.path.dropFirst(root.path.count).split(separator: "/")
        var current = root
        for component in components {
            current.appendPathComponent(String(component))
            if FileManager.default.fileExists(atPath: current.path) {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw LoadSideError("archive.parent", "Archive entry has an unsafe parent directory.")
                }
            } else {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
    }
    private static func validateLink(_ link: String, from file: URL, root: URL) throws {
        guard !link.isEmpty, !link.hasPrefix("/"), !link.contains("\\"), !link.contains(":"), link.utf8.count <= 4096 else {
            throw LoadSideError("archive.symlink", "Archive contains an unsafe symbolic link.")
        }
        let target = file.deletingLastPathComponent().appendingPathComponent(link).standardizedFileURL.path
        guard target.hasPrefix(root.path + "/") else {
            throw LoadSideError("archive.symlink", "Archive symbolic link escapes its workspace.")
        }
    }
    private static func limit(_ reason: String) -> LoadSideError {
        LoadSideError(
            "archive.limit", "Archive safety limit exceeded: \(reason).",
            recovery: "Use a smaller archive or review its contents for excessive expansion.")
    }
    private static func failure(_ archive: OpaquePointer, _ operation: String) -> LoadSideError {
        let detail = archive_error_string(archive).map { String(cString: $0) } ?? "Unknown libarchive error"
        return LoadSideError("archive.io", "Unable to \(operation): \(detail)")
    }
}
