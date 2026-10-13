import Darwin
import Foundation
import LoadSideCore

enum PasswordInput {
    private static let maximumFileBytes = 16_384

    static func read(_ options: CommandOptions) throws -> String {
        if options.flags.contains("--password-stdin"), options.values["--password-file"] != nil {
            throw LoadSideError("arguments.password", "Choose one password input method.", recovery: "Use either --password-stdin or --password-file, or omit both for a hidden terminal prompt.")
        }
        if options.flags.contains("--password-stdin") {
            guard let value = readLine(strippingNewline: true) else {
                throw LoadSideError("credentials.password", "No password was supplied on standard input.", recovery: "Supply one line; an empty line is valid for an unprotected P12.")
            }
            return value
        }
        if let path = options.values["--password-file"]?.first {
            return try readFile(at: URL(fileURLWithPath: path))
        }
        guard isatty(STDIN_FILENO) == 1, let pointer = getpass("P12 password (hidden): ") else {
            throw LoadSideError("credentials.password", "An interactive terminal is required to enter the P12 password.", recovery: "Use --password-stdin or --password-file for automation. Password command-line arguments are intentionally unsupported.")
        }
        defer { memset(pointer, 0, strlen(pointer)) }
        return String(cString: pointer)
    }

    static func readFile(at url: URL) throws -> String {
        // Open once, reject links and special files, and validate the same descriptor
        // we read. Nonblocking open prevents a named pipe from hanging the CLI.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw LoadSideError("credentials.password", "The password file could not be opened.", recovery: "Choose a readable, regular file with owner-only permissions; symbolic links are not supported.")
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw LoadSideError("credentials.password", "The password file must be a regular file.")
        }
        guard info.st_mode & 0o077 == 0 else {
            throw LoadSideError("credentials.permissions", "The password file is accessible to other users.", recovery: "Set its permissions to 600, or use the hidden terminal prompt.")
        }
        guard info.st_size >= 0, info.st_size <= maximumFileBytes else { throw invalidContents() }

        // Keep the read bounded even if another process grows the opened file.
        var bytes = [UInt8](repeating: 0, count: maximumFileBytes + 1)
        var count = 0
        while count < bytes.count {
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw LoadSideError("credentials.password", "The password file could not be read.")
            }
            count += readCount
        }
        guard count <= maximumFileBytes else { throw invalidContents() }
        // CRLF is one Swift Character, so strip its exact bytes before decoding.
        // Preserve every password byte before the final LF or CRLF sequence.
        if count > 0, bytes[count - 1] == 0x0a {
            count -= 1
            if count > 0, bytes[count - 1] == 0x0d { count -= 1 }
        }
        guard let value = String(bytes: bytes.prefix(count), encoding: .utf8) else { throw invalidContents() }
        return value
    }

    private static func invalidContents() -> LoadSideError {
        LoadSideError("credentials.password", "The password file must contain at most 16 KiB of UTF-8 text.")
    }
}
