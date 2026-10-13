import CryptoKit
import Darwin
import Foundation

/// Shared input checks and output transaction for signed and unsigned IPA jobs.
/// The destination appears only after packaging, hashing, and a final cancellation check.
enum IPAExport {
    static func validatePaths(ipa: URL, output: URL) throws {
        guard ipa.isFileURL, try ipa.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LoadSideError("request.ipa", "The source IPA must be a regular local file.")
        }
        guard output.isFileURL, output.pathExtension.lowercased() == "ipa" else {
            throw LoadSideError("request.output", "Choose a local output file ending in .ipa.")
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw LoadSideError("output.exists", "An output file already exists at this destination.", recovery: "Choose another output name. LoadSide never overwrites an existing export.")
        }
    }

    static func validateInputs(_ inputs: [URL], output: URL) throws {
        let resolvedOutput = output.resolvingSymlinksInPath()
        for input in inputs {
            guard input.isFileURL, FileManager.default.isReadableFile(atPath: input.path) else {
                throw LoadSideError("request.input", "Cannot read input \(input.lastPathComponent).")
            }
            guard input.resolvingSymlinksInPath() != resolvedOutput else {
                throw LoadSideError("request.outputInput", "The output cannot replace a source file.")
            }
        }
    }

    static func write(from directory: URL, to destination: URL) throws -> String {
        // A sibling staging file keeps the exclusive rename atomic on the output volume.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".LoadSide-\(UUID().uuidString).ipa")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Archive.createIPA(from: directory, to: staging)
        let hash = try sha256(staging)
        try Task.checkCancellation()
        try commit(staging: staging, destination: destination)
        return hash
    }

    static func commit(staging: URL, destination: URL) throws {
        guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw LoadSideError("output.commit", "Could not atomically create the export: \(String(cString: strerror(errno))).", recovery: "Choose a writable destination and a filename that does not already exist.")
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().hex
    }
}
