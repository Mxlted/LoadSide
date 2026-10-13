import Darwin
import Foundation

/// Reads an untrusted local file through the descriptor whose type and size were
/// checked. Nonblocking open rejects FIFOs without waiting for a writer, and the
/// streaming bound still applies if a regular file grows after inspection.
enum BoundedFile {
    static func read(
        _ url: URL, maximumBytes: Int, minimumBytes: Int = 0, followingSymlinks: Bool = false,
        invalid: LoadSideError
    ) throws -> Data {
        try Task.checkCancellation()
        guard url.isFileURL, maximumBytes > 0, maximumBytes < Int.max, (0...maximumBytes).contains(minimumBytes) else {
            throw invalid
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followingSymlinks ? 0 : O_NOFOLLOW))
        guard descriptor >= 0 else { throw invalid }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
            initial.st_size >= Int64(minimumBytes), initial.st_size <= Int64(maximumBytes)
        else { throw invalid }

        var data = Data()
        data.reserveCapacity(Int(initial.st_size))
        while true {
            try Task.checkCancellation()
            let remaining = maximumBytes - data.count + 1
            guard let block = try handle.read(upToCount: min(64 * 1_024, remaining)), !block.isEmpty else { break }
            data.append(block)
            guard data.count <= maximumBytes else { throw invalid }
        }
        var final = stat()
        guard data.count >= minimumBytes, Int64(data.count) == initial.st_size,
            fstat(descriptor, &final) == 0, initial.st_size == final.st_size,
            initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec, initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
            initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec, initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
        else { throw invalid }
        try Task.checkCancellation()
        return data
    }
}
