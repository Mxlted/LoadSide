import Darwin
import Foundation
import Network
import Security

public struct LocalAppServerSession: Sendable {
    public let localURL: URL
    public let networkURLs: [URL]
    public let httpsURL: URL?
    public let port: UInt16
    public var browserURL: URL { httpsURL ?? networkURLs.first ?? localURL }
    /// Configured HTTPS is not a certificate trust or device eligibility verdict.
    public var installEnabled: Bool { httpsURL != nil }
    public func downloadURL(for app: LocalAppRecord) -> URL { browserURL.appendingPathComponent("apps/\(app.id.uuidString).ipa") }
    public func installURL(for app: LocalAppRecord) -> URL? {
        guard app.supportsInstallation, let httpsURL else { return nil }
        var components = URLComponents()
        components.scheme = "itms-services"
        components.host = ""
        components.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: httpsURL.appendingPathComponent("apps/\(app.id.uuidString).plist").absoluteString)
        ]
        return components.url
    }
}

/// An opt-in, read-only HTTP server. A fresh 256-bit capability URL limits access to explicitly
/// published library copies. HTTP is unencrypted; only share the URL on a trusted local network.
/// OTA uses a configured HTTPS reverse proxy or an explicitly started managed tunnel.
public actor LocalAppServer {
    private let library: LocalAppLibrary
    private let onFailure: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "app.loadside.library-network", qos: .utility)
    private var listener: NWListener?
    private var generation: UUID?
    private var continuation: CheckedContinuation<LocalAppServerSession, any Error>?
    private var session: LocalAppServerSession?
    private var clients: [UUID: LocalHTTPClient] = [:]

    public init(library: LocalAppLibrary, onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.library = library
        self.onFailure = onFailure
    }

    deinit {
        listener?.cancel()
        for client in clients.values { Task { await client.cancel() } }
    }

    public func start(port: UInt16 = 0, httpsBaseURL: URL? = nil) async throws -> LocalAppServerSession {
        guard listener == nil else { throw LoadSideError("server.running", "Stop sharing before changing its configuration.") }
        let base = try LocalHTTP.validateHTTPSBase(httpsBaseURL)
        _ = try await library.library()
        // Library validation suspends; another start may have arrived in the meantime.
        guard listener == nil else { throw LoadSideError("server.running", "The local server is already starting.") }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw LoadSideError("server.random", "Could not create a private sharing link.")
        }
        let token = random.map { String(format: "%02x", $0) }.joined()
        let id = UUID()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener = newListener
        generation = id
        newListener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerChanged(state, id: id, token: token, httpsBase: base) }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection, generation: id) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                newListener.start(queue: queue)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    await self?.startupTimedOut(id)
                }
            }
        } onCancel: {
            Task { await self.stop(ifGeneration: id) }
        }
    }

    public func stop() async { await stop(ifGeneration: generation) }
    public func currentSession() -> LocalAppServerSession? { session }

    /// Attach a ready tunnel without restarting the listener or changing its capability token.
    /// The expected local URL prevents delayed setup from changing a newer sharing session.
    public func configureHTTPS(baseURL: URL, expectedLocalURL: URL) throws -> LocalAppServerSession {
        let base = try LocalHTTP.validateHTTPSBase(baseURL)!
        guard let current = session, current.localURL == expectedLocalURL else {
            throw LoadSideError("server.session", "The sharing session ended before HTTPS became ready. Start sharing again.")
        }
        let updated = LocalAppServerSession(
            localURL: current.localURL, networkURLs: current.networkURLs,
            httpsURL: base.appendingPathComponent(current.localURL.lastPathComponent, isDirectory: true), port: current.port)
        session = updated
        return updated
    }

    private func stop(ifGeneration id: UUID?) async {
        guard generation == id else { return }
        generation = nil
        listener?.cancel()
        listener = nil
        session = nil
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        let active = Array(clients.values)
        clients.removeAll()
        for client in active { await client.cancel() }
    }
    private func startupTimedOut(_ id: UUID) async {
        guard generation == id, continuation != nil else { return }
        continuation?.resume(
            throwing: LoadSideError("server.timeout", "The local server did not become ready. Check macOS network permissions."))
        continuation = nil
        await stop(ifGeneration: id)
    }
    private func listenerChanged(_ state: NWListener.State, id: UUID, token: String, httpsBase: URL?) async {
        guard generation == id else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            let local = URL(string: "http://127.0.0.1:\(port)/\(token)/")!
            let network = Self.networkAddresses().compactMap { URL(string: "http://\($0):\(port)/\(token)/") }
            let session = LocalAppServerSession(
                localURL: local, networkURLs: network,
                httpsURL: httpsBase?.appendingPathComponent(token, isDirectory: true), port: port)
            self.session = session
            continuation?.resume(returning: session)
            continuation = nil
        case .failed:
            let message = "Local sharing stopped because the network listener failed. Restart sharing and check macOS network permissions."
            continuation?.resume(throwing: LoadSideError("server.failed", message))
            continuation = nil
            onFailure(message)
            await stop(ifGeneration: id)
        case .cancelled:
            if listener != nil {
                onFailure("Local sharing stopped because the network listener was cancelled.")
                await stop(ifGeneration: id)
            }
        default: break
        }
    }
    private func accept(_ connection: NWConnection, generation id: UUID) async {
        guard generation == id, let session, clients.count < 8 else {
            connection.cancel()
            return
        }
        let clientID = UUID()
        let client = LocalHTTPClient(connection: connection, queue: queue, library: library, session: session) { [weak self] in
            Task { await self?.finished(clientID) }
        }
        clients[clientID] = client
        await client.start()
    }
    private func finished(_ id: UUID) { clients.removeValue(forKey: id) }

    private static func networkAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        var addresses: [String: Int] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let item = current.pointee
            guard item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let host = String(decoding: bytes, as: UTF8.self)
                let interface = item.ifa_name.map { String(cString: $0) } ?? ""
                let octets = host.split(separator: ".").compactMap { Int($0) }
                let isPrivate =
                    octets.count == 4
                    && (octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168))
                let score = (interface.hasPrefix("en") ? 0 : 2) + (isPrivate ? 0 : 1)
                addresses[host] = min(addresses[host] ?? score, score)
            }
        }
        return addresses.keys.sorted { addresses[$0] == addresses[$1] ? $0 < $1 : addresses[$0]! < addresses[$1]! }
    }
}

private actor LocalHTTPClient {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let library: LocalAppLibrary
    private let session: LocalAppServerSession
    private let onFinish: @Sendable () -> Void
    private var input = Data()
    private var finished = false
    private var responseStarted = false
    private var deadline: Task<Void, Never>?
    private var lifetime: Task<Void, Never>?
    private var work: Task<Void, Never>?

    init(
        connection: NWConnection, queue: DispatchQueue, library: LocalAppLibrary, session: LocalAppServerSession,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.library = library
        self.session = session
        self.onFinish = onFinish
    }
    func start() {
        connection.start(queue: queue)
        armTimeout(seconds: 10)
        lifetime = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1_800))
                await self?.cancel()
            } catch {}
        }
        receive()
    }
    func cancel() {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        lifetime?.cancel()
        work?.cancel()
        connection.cancel()
        onFinish()
    }
    private func armTimeout(seconds: Int) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
                await self?.cancel()
            } catch {}
        }
    }
    private func receive() {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, done, error in
            Task { await self?.received(data, done: done, failed: error != nil) }
        }
    }
    private func received(_ data: Data?, done: Bool, failed: Bool) async {
        guard !finished else { return }
        if failed {
            cancel()
            return
        }
        if let data { input.append(data) }
        guard input.count <= LocalHTTP.maximumHeaderBytes else {
            await error(431)
            return
        }
        if input.range(of: Data("\r\n\r\n".utf8)) != nil {
            let requestData = input
            input.removeAll()
            // A bounded preparation window allows large IPA hashes and queued disk reads;
            // incomplete headers still have only ten seconds.
            armTimeout(seconds: 120)
            work = Task { [weak self] in await self?.respond(requestData) }
        } else if done {
            cancel()
        } else {
            receive()
        }
    }
    private func respond(_ data: Data) async {
        do {
            let request = try LocalHTTP.parse(data)
            guard request.method == "GET" || request.method == "HEAD" else {
                await error(405)
                return
            }
            guard let route = LocalHTTP.route(request.target, localURL: session.localURL) else {
                await error(404)
                return
            }
            let headOnly = request.method == "HEAD"
            switch route {
            case .catalog:
                try await respondCatalog(headOnly: headOnly)
            case let .manifest(id):
                try await respondManifest(id, headOnly: headOnly)
            case let .archive(id):
                try await respondArchive(id, rangeHeader: request.headers["range"], headOnly: headOnly)
            }
        } catch is CancellationError {
            cancel()
        } catch {
            // Never expose paths, metadata decode errors, or credentials over HTTP.
            await self.error(404)
        }
    }

    private func respondCatalog(headOnly: Bool) async throws {
        let catalog = try await library.library()
        let page = LocalHTTP.page(catalog.apps, session: session)
        try await respondData(Data(page.utf8), type: "text/html; charset=utf-8", headOnly: headOnly)
    }

    private func respondManifest(_ id: UUID, headOnly: Bool) async throws {
        guard let https = session.httpsURL else {
            await error(404)
            return
        }
        let app = try await library.record(id)
        guard app.supportsInstallation else {
            await error(404)
            return
        }
        let data = try LocalHTTP.manifest(app, baseURL: https)
        try await respondData(data, type: "text/xml; charset=utf-8", headOnly: headOnly)
    }

    private func respondArchive(_ id: UUID, rangeHeader: String?, headOnly: Bool) async throws {
        let download = try await library.download(id)
        defer { try? download.handle.close() }
        guard !finished else { return }

        let size = download.record.byteCount
        let range: ClosedRange<Int64>
        do { range = try LocalHTTP.byteRange(rangeHeader, size: size) } catch {
            await self.error(416, extra: "Content-Range: bytes */\(size)\r\n")
            return
        }
        let partial = rangeHeader != nil
        let length = range.upperBound - range.lowerBound + 1
        var extra = "Accept-Ranges: bytes\r\nContent-Disposition: attachment; filename=\"\(id.uuidString).ipa\"\r\n"
        if partial { extra += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(size)\r\n" }
        try await sendHeaders(status: partial ? 206 : 200, length: length, type: "application/octet-stream", extra: extra)
        if !headOnly {
            try download.handle.seek(toOffset: UInt64(range.lowerBound))
            var remaining = length
            while remaining > 0 {
                try Task.checkCancellation()
                guard !finished,
                    let block = try download.handle.read(upToCount: Int(min(256 * 1_024, remaining))),
                    !block.isEmpty
                else { throw CancellationError() }
                try await send(block)
                remaining -= Int64(block.count)
            }
        }
        await completeResponse()
    }

    private func sendHeaders(status: Int, length: Int64, type: String, extra: String = "") async throws {
        // Even a failed send may have written part of the headers. Once committed, any
        // preparation or transport failure must close the stream, never append a response.
        responseStarted = true
        try await send(LocalHTTP.headers(status: status, length: length, type: type, extra: extra))
    }

    private func send(_ data: Data) async throws {
        guard !finished else { throw CancellationError() }
        armTimeout(seconds: 30)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }
    private func respondData(_ data: Data, type: String, headOnly: Bool) async throws {
        try await sendHeaders(status: 200, length: Int64(data.count), type: type)
        if !headOnly { try await send(data) }
        await completeResponse()
    }
    private func error(_ status: Int, extra: String = "") async {
        guard !finished else { return }
        guard !responseStarted else {
            cancel()
            return
        }
        try? await sendHeaders(status: status, length: 0, type: "text/plain", extra: extra)
        await completeResponse()
    }
    private func completeResponse() async {
        guard !finished else { return }
        // End the TCP write stream before releasing the connection so a successful response
        // is cleanly delimited after all back-pressured sends have been processed.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in continuation.resume() })
        }
        cancel()
    }
}
