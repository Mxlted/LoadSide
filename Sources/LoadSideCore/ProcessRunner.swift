import Darwin
import Foundation

struct ProcessOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var diagnostic: String {
        String(decoding: stderr.isEmpty ? stdout : stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs trusted system tools without a shell. File-backed output avoids pipe deadlocks;
/// deadlines, cancellation and byte limits bound every child process.
struct ProcessRunner: Sendable {
    func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 120,
        maximumOutput: Int = 4 * 1_024 * 1_024, check: Bool = true
    ) async throws -> ProcessOutput {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LoadSide-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("stdout")
        let stderr = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdout.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderr.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        defer {
            try? out.close()
            try? err.close()
        }
        let child = ManagedChild()
        child.process.executableURL = URL(fileURLWithPath: executable)
        child.process.arguments = arguments
        child.process.standardInput = FileHandle.nullDevice
        child.process.standardOutput = out
        child.process.standardError = err
        child.process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": NSHomeDirectory(), "TMPDIR": directory.path
        ]
        return try await withTaskCancellationHandler {
            try child.launch()
            let start = ContinuousClock.now
            do {
                while child.process.isRunning {
                    try Task.checkCancellation()
                    if start.duration(to: .now) > .seconds(timeout) {
                        throw LoadSideError(
                            "tool.timeout",
                            "\(URL(fileURLWithPath: executable).lastPathComponent) exceeded its \(Int(timeout))-second deadline.",
                            recovery: "Close any Keychain prompts, verify the certificate password, and retry.")
                    }
                    let bytes = try [stdout, stderr].reduce(0) { total, url in
                        total + ((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
                    }
                    if bytes > maximumOutput {
                        throw LoadSideError("tool.outputLimit", "A system tool exceeded the diagnostic output limit.")
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
            } catch {
                child.stop()
                await child.waitForTermination()
                throw error
            }
            try Task.checkCancellation()
            let result = ProcessOutput(
                status: child.process.terminationStatus,
                stdout: try readBounded(stdout, limit: maximumOutput),
                stderr: try readBounded(stderr, limit: maximumOutput))
            guard result.stdout.count + result.stderr.count <= maximumOutput else {
                throw LoadSideError("tool.outputLimit", "A system tool exceeded the diagnostic output limit.")
            }
            if check && result.status != 0 {
                throw LoadSideError(
                    "tool.failed",
                    "\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(result.status)): \(result.diagnostic.prefix(8_192))",
                    recovery: "Review the diagnostic, correct the affected input, and retry. Your source files were not modified.")
            }
            return result
        } onCancel: {
            child.stop()
        }
    }

    private func readBounded(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw LoadSideError("tool.outputLimit", "A system tool exceeded the diagnostic output limit.") }
        return data
    }
}

private final class ManagedChild: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var stopped = false
    private var terminated = false
    private var terminationWaiter: CheckedContinuation<Void, Never>?
    func launch() throws {
        lock.lock()
        defer { lock.unlock() }
        if stopped { throw CancellationError() }
        process.terminationHandler = { [weak self] _ in self?.didTerminate() }
        try process.run()
    }
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    func waitForTermination() async {
        // Foundation's termination callback runs after it reaps the child.
        // waitUntilExit on a detached Swift task can stall its thread's run loop.
        await withCheckedContinuation { continuation in
            lock.lock()
            if terminated {
                lock.unlock()
                continuation.resume()
            } else {
                terminationWaiter = continuation
                lock.unlock()
            }
        }
    }
    private func didTerminate() {
        lock.lock()
        terminated = true
        let waiter = terminationWaiter
        terminationWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}
