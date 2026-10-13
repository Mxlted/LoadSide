import Foundation
import Darwin

/// An explicitly started, temporary HTTPS connection to the local catalog. Only a trusted
/// cloudflared executable is launched; imported archives and their contents are never executed.
public actor LocalAppTunnel {
    private let onFailure: @Sendable (String) -> Void
    private let startupTimeout: Duration
    private let terminationNotificationDelay: Duration
    private var child: LocalTunnelChild?
    private var generation: UUID?
    private var cleanups: [UUID: Task<Void, Never>] = [:]
    private var monitor: Task<Void, Never>?
    private var output = LocalTunnelOutput()

    public init(onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onFailure = onFailure
        startupTimeout = .seconds(60)
        terminationNotificationDelay = .zero
    }

    init(startupTimeout: Duration, terminationNotificationDelay: Duration = .zero,
         onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.startupTimeout = startupTimeout
        self.terminationNotificationDelay = terminationNotificationDelay
        self.onFailure = onFailure
    }

    deinit { monitor?.cancel(); child?.stop(); child?.cleanFiles() }

    public func start(executable: URL, port: UInt16) async throws -> URL {
        guard child == nil else { throw failure("running", "Stop HTTPS sharing before starting another connection.") }
        guard port > 0, executable.isFileURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw failure("configuration", "Choose an executable cloudflared helper and a valid local port.")
        }
        try Task.checkCancellation()
        let newChild: LocalTunnelChild
        do { newChild = try LocalTunnelChild(executable: executable, port: port, terminationNotificationDelay: terminationNotificationDelay) }
        catch { throw failure("launch", "The HTTPS helper could not be prepared. Check its installation and retry.") }
        let id = UUID()
        child = newChild; generation = id; output = LocalTunnelOutput()
        return try await withTaskCancellationHandler {
            do {
                try newChild.launch()
                let started = ContinuousClock.now
                while true {
                    try Task.checkCancellation()
                    guard generation == id else { throw CancellationError() }
                    guard newChild.isRunning else { throw failure("exited", "The HTTPS helper stopped before connecting. Check the network and helper installation, then retry.") }
                    try output.consume(newChild.readAvailable())
                    if let url = output.url, output.registered {
                        try Task.checkCancellation()
                        monitor = Task { [weak self] in
                            while !Task.isCancelled {
                                guard await self?.pollRunning(id: id) == true else { return }
                                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                            }
                        }
                        return url
                    }
                    guard started.duration(to: .now) < startupTimeout else {
                        throw failure("timeout", "The HTTPS connection did not become ready. Check internet access and retry.")
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
            } catch {
                await stop(ifGeneration: id)
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let error = error as? LoadSideError { throw error }
                throw failure("launch", "The HTTPS helper could not run. Check its installation and retry.")
            }
        } onCancel: { newChild.stop() }
    }

    public func stop() async {
        // A listener failure or another caller may already have detached the process while
        // waiting for Foundation to reap it. Every stop also waits for those earlier cleanups.
        let pending = Array(cleanups.values)
        await stop(ifGeneration: generation)
        for cleanup in pending { await cleanup.value }
    }

    private func stop(ifGeneration id: UUID?) async {
        guard let id else { return }
        if let cleanup = cleanups[id] { await cleanup.value; return }
        guard generation == id else { return }
        generation = nil
        monitor?.cancel(); monitor = nil
        let active = child; child = nil
        guard let active else { return }
        active.stop()
        let cleanup = Task {
            await active.waitForTermination()
            active.cleanFiles()
        }
        cleanups[id] = cleanup
        await cleanup.value
        cleanups.removeValue(forKey: id)
    }

    private func pollRunning(id: UUID) async -> Bool {
        guard generation == id, let child else { return false }
        do {
            guard child.isRunning else { throw failure("exited", "The HTTPS connection ended. Start sharing again to create a new link.") }
            try output.consume(child.readAvailable())
            return true
        } catch {
            await stop(ifGeneration: id)
            // A previous generation must never clear the UI for a newly started connection.
            if generation == nil {
                onFailure("The HTTPS connection ended. Start sharing again to create a new link.")
            }
            return false
        }
    }

    private func failure(_ code: String, _ message: String) -> LoadSideError {
        LoadSideError("tunnel.\(code)", message)
    }
}

/// Reads complete records, including split UTF-8/JSON writes. No raw tool diagnostics are
/// exposed: they can contain paths or values from the helper's environment.
struct LocalTunnelOutput {
    private var pending = Data()
    private(set) var url: URL?
    private(set) var registered = false

    mutating func consume(_ data: Data) throws {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            guard line.utf8.count <= 16_384 else { throw outputLimit() }
            consumeLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard pending.count <= 16_384 else { throw outputLimit() }
    }

    private mutating func consumeLine(_ line: String) {
        let message: String
        if line.hasPrefix("{") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let text = record["message"] as? String else { return }
            message = text
            if text == "Registered tunnel connection", record["level"] as? String == "info" { registered = true }
        } else {
            message = line
            if line == "Registered tunnel connection" || line.contains(" INF Registered tunnel connection ") { registered = true }
        }
        for token in message.split(whereSeparator: \.isWhitespace) {
            guard token.hasPrefix("https://"), let candidate = Self.safeURL(String(token)) else { continue }
            if url == nil { url = candidate }
        }
    }

    private static func safeURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value), components.scheme == "https",
              let host = components.host, host.hasSuffix(".trycloudflare.com"),
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              value == "https://\(host)" else { return nil }
        let label = String(host.dropLast(".trycloudflare.com".count))
        guard (1...63).contains(label.utf8.count),
              label.first?.isASCII == true, label.last?.isASCII == true,
              label.first?.isLetter == true || label.first?.isNumber == true,
              label.last?.isLetter == true || label.last?.isNumber == true,
              label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
        return components.url
    }

    private func outputLimit() -> LoadSideError {
        LoadSideError("tunnel.outputLimit", "The HTTPS helper exceeded its diagnostic limit. Restart sharing to try again.")
    }
}

/// Cancellation can arrive outside the actor while Process.run is in progress. This lock
/// serializes launch/termination and the termination callback reaps the owned child.
private final class LocalTunnelChild: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private let directory: URL
    private let diagnosticURL: URL
    private let writer: FileHandle
    private let reader: FileHandle
    private let terminationNotificationDelay: Duration
    private var stopped = false
    private var launched = false
    private var terminated = false
    private var cleaned = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(executable: URL, port: UInt16, terminationNotificationDelay: Duration) throws {
        self.terminationNotificationDelay = terminationNotificationDelay
        let manager = FileManager.default
        directory = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("LoadSide-tunnel-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        diagnosticURL = directory.appendingPathComponent("diagnostics")
        do {
            let configuration = directory.appendingPathComponent("empty-config.yml")
            guard manager.createFile(atPath: configuration.path, contents: Data("{}\n".utf8), attributes: [.posixPermissions: 0o600]),
                  manager.createFile(atPath: diagnosticURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw LoadSideError("tunnel.files", "The HTTPS helper workspace could not be created.")
            }
            writer = try FileHandle(forWritingTo: diagnosticURL)
            reader = try FileHandle(forReadingFrom: diagnosticURL)
            process.executableURL = executable
            process.arguments = ["tunnel", "--config", configuration.path, "--no-autoupdate",
                                 "--url", "http://127.0.0.1:\(port)", "--protocol", "http2",
                                 "--metrics", "127.0.0.1:0", "--loglevel", "info", "--output", "json"]
            process.currentDirectoryURL = directory
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": directory.path, "TMPDIR": directory.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = writer
            process.standardError = writer
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    deinit { stop(); cleanFiles() }

    var isRunning: Bool { lock.withLock { launched && process.isRunning } }

    func launch() throws {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            let delay = terminationNotificationDelay
            process.terminationHandler = { [weak self] _ in
                if delay == .zero { self?.didTerminate() }
                else {
                    // Tests can hold the real process's termination notification to exercise
                    // concurrent stop/cleanup behavior without relying on scheduler timing.
                    Task { [self] in
                        try? await Task.sleep(for: delay)
                        self?.didTerminate()
                    }
                }
            }
            try process.run()
            launched = true
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            if launched && process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func waitForTermination() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !launched || terminated {
                lock.unlock(); continuation.resume()
            } else {
                waiters.append(continuation); lock.unlock()
            }
        }
    }

    func readAvailable() throws -> Data {
        let bytes = (try FileManager.default.attributesOfItem(atPath: diagnosticURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard bytes <= 2 * 1_024 * 1_024 else {
            throw LoadSideError("tunnel.outputLimit", "The HTTPS helper exceeded its diagnostic limit. Restart sharing to try again.")
        }
        return try reader.read(upToCount: 64 * 1_024) ?? Data()
    }

    func cleanFiles() {
        let needsCleanup = lock.withLock {
            guard !cleaned else { return false }
            cleaned = true
            return true
        }
        guard needsCleanup else { return }
        try? writer.close(); try? reader.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func didTerminate() {
        lock.lock()
        terminated = true
        let pending = waiters; waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}
