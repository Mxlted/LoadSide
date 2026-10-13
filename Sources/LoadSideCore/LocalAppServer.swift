import Foundation
import Network
import Security
import Darwin

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
        components.scheme = "itms-services"; components.host = ""
        components.queryItems = [URLQueryItem(name: "action", value: "download-manifest"),
                                 URLQueryItem(name: "url", value: httpsURL.appendingPathComponent("apps/\(app.id.uuidString).plist").absoluteString)]
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
        self.library = library; self.onFailure = onFailure
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
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw LoadSideError("server.random", "Could not create a private sharing link.") }
        let token = random.map { String(format: "%02x", $0) }.joined(), id = UUID()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        let newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener = newListener; generation = id
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
        let updated = LocalAppServerSession(localURL: current.localURL, networkURLs: current.networkURLs,
            httpsURL: base.appendingPathComponent(current.localURL.lastPathComponent, isDirectory: true), port: current.port)
        session = updated
        return updated
    }

    private func stop(ifGeneration id: UUID?) async {
        guard generation == id else { return }
        generation = nil; listener?.cancel(); listener = nil; session = nil
        continuation?.resume(throwing: CancellationError()); continuation = nil
        let active = Array(clients.values); clients.removeAll()
        for client in active { await client.cancel() }
    }
    private func startupTimedOut(_ id: UUID) async {
        guard generation == id, continuation != nil else { return }
        continuation?.resume(throwing: LoadSideError("server.timeout", "The local server did not become ready. Check macOS network permissions.")); continuation = nil
        await stop(ifGeneration: id)
    }
    private func listenerChanged(_ state: NWListener.State, id: UUID, token: String, httpsBase: URL?) async {
        guard generation == id else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            let local = URL(string: "http://127.0.0.1:\(port)/\(token)/")!
            let network = Self.networkAddresses().compactMap { URL(string: "http://\($0):\(port)/\(token)/") }
            let session = LocalAppServerSession(localURL: local, networkURLs: network,
                httpsURL: httpsBase?.appendingPathComponent(token, isDirectory: true), port: port)
            self.session = session
            continuation?.resume(returning: session); continuation = nil
        case .failed:
            let message = "Local sharing stopped because the network listener failed. Restart sharing and check macOS network permissions."
            continuation?.resume(throwing: LoadSideError("server.failed", message)); continuation = nil
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
        guard generation == id, let session, clients.count < 8 else { connection.cancel(); return }
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
        var addresses: [String: Int] = [:], pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let item = current.pointee
            guard item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let host = String(decoding: bytes, as: UTF8.self)
                let interface = item.ifa_name.map { String(cString: $0) } ?? ""
                let octets = host.split(separator: ".").compactMap { Int($0) }
                let isPrivate = octets.count == 4 && (octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168))
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
    private var deadline: Task<Void, Never>?
    private var lifetime: Task<Void, Never>?
    private var work: Task<Void, Never>?

    init(connection: NWConnection, queue: DispatchQueue, library: LocalAppLibrary, session: LocalAppServerSession,
         onFinish: @escaping @Sendable () -> Void) {
        self.connection = connection; self.queue = queue; self.library = library; self.session = session; self.onFinish = onFinish
    }
    func start() {
        connection.start(queue: queue)
        armTimeout(seconds: 10)
        lifetime = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1_800)); await self?.cancel() } catch {}
        }
        receive()
    }
    func cancel() {
        guard !finished else { return }
        finished = true
        deadline?.cancel(); lifetime?.cancel(); work?.cancel()
        connection.cancel(); onFinish()
    }
    private func armTimeout(seconds: Int) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)); await self?.cancel() } catch {}
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
        if failed { cancel(); return }
        if let data { input.append(data) }
        guard input.count <= LocalHTTP.maximumHeaderBytes else { await error(431); return }
        if input.range(of: Data("\r\n\r\n".utf8)) != nil {
            let requestData = input
            input.removeAll()
            // A bounded preparation window allows large IPA hashes and queued disk reads;
            // incomplete headers still have only ten seconds.
            armTimeout(seconds: 120)
            work = Task { [weak self] in await self?.respond(requestData) }
        } else if done { cancel() } else { receive() }
    }
    private func respond(_ data: Data) async {
        do {
            let request = try LocalHTTP.parse(data)
            guard request.method == "GET" || request.method == "HEAD" else { await error(405); return }
            let prefix = session.localURL.path.hasSuffix("/") ? session.localURL.path : session.localURL.path + "/"
            guard request.target.hasPrefix(prefix) else { await error(404); return }
            let relative = String(request.target.dropFirst(prefix.count))
            if relative.isEmpty {
                let catalog = try await library.library()
                let page = LocalHTTP.page(catalog.apps, session: session)
                try await respondData(Data(page.utf8), type: "text/html; charset=utf-8", headOnly: request.method == "HEAD")
            } else {
                let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, parts[0] == "apps" else { await error(404); return }
                let name = String(parts[1]), isManifest = name.hasSuffix(".plist"), suffix = isManifest ? ".plist" : ".ipa"
                guard name.hasSuffix(suffix), let id = UUID(uuidString: String(name.dropLast(suffix.count))), name == id.uuidString + suffix else { await error(404); return }
                if isManifest {
                    guard let https = session.httpsURL else { await error(404); return }
                    let app = try await library.record(id)
                    guard app.supportsInstallation else { await error(404); return }
                    let data = try LocalHTTP.manifest(app, baseURL: https)
                    try await respondData(data, type: "text/xml; charset=utf-8", headOnly: request.method == "HEAD")
                } else {
                    let download = try await library.download(id)
                    defer { try? download.handle.close() }
                    guard !finished else { return }
                    let size = download.record.byteCount
                    let range: ClosedRange<Int64>
                    do { range = try LocalHTTP.byteRange(request.headers["range"], size: size) }
                    catch { await self.error(416, extra: "Content-Range: bytes */\(size)\r\n"); return }
                    let partial = request.headers["range"] != nil, length = range.upperBound - range.lowerBound + 1
                    var extra = "Accept-Ranges: bytes\r\nContent-Disposition: attachment; filename=\"\(id.uuidString).ipa\"\r\n"
                    if partial { extra += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound)/\(size)\r\n" }
                    try await send(LocalHTTP.headers(status: partial ? 206 : 200, length: length, type: "application/octet-stream", extra: extra))
                    if request.method != "HEAD" {
                        try download.handle.seek(toOffset: UInt64(range.lowerBound))
                        var remaining = length
                        while remaining > 0 {
                            try Task.checkCancellation()
                            guard !finished, let block = try download.handle.read(upToCount: Int(min(256 * 1_024, remaining))), !block.isEmpty else { throw CancellationError() }
                            try await send(block); remaining -= Int64(block.count)
                        }
                    }
                    await completeResponse()
                }
            }
        } catch is CancellationError { cancel() }
        catch { await self.error(404) } // Never expose paths, metadata decode errors, or credentials over HTTP.
    }
    private func send(_ data: Data) async throws {
        guard !finished else { throw CancellationError() }
        armTimeout(seconds: 30)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func respondData(_ data: Data, type: String, headOnly: Bool) async throws {
        try await send(LocalHTTP.headers(status: 200, length: Int64(data.count), type: type))
        if !headOnly { try await send(data) }
        await completeResponse()
    }
    private func error(_ status: Int, extra: String = "") async {
        guard !finished else { return }
        try? await send(LocalHTTP.headers(status: status, length: 0, type: "text/plain", extra: extra))
        await completeResponse()
    }
    private func completeResponse() async {
        guard !finished else { return }
        // End the TCP write stream before releasing the connection so a successful response
        // is cleanly delimited after all back-pressured sends have been processed.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in continuation.resume() })
        }
        cancel()
    }
}

enum LocalHTTP {
    static let maximumHeaderBytes = 16 * 1_024
    struct Request { let method: String; let target: String; let headers: [String: String] }
    static func validateHTTPSBase(_ url: URL?) throws -> URL? {
        guard let url else { return nil }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path == "" || parts.path == "/",
              parts.port == nil || (1...65_535).contains(parts.port!) else {
            throw LoadSideError("server.https", "Use an HTTPS origin such as https://apps.example.com, without a path, credentials, query, or fragment.")
        }
        return url
    }
    static func parse(_ data: Data) throws -> Request {
        guard data.count <= maximumHeaderBytes, let string = String(data: data, encoding: .ascii), string.hasSuffix("\r\n\r\n") else { throw invalid() }
        let lines = string.dropLast(4).components(separatedBy: "\r\n")
        guard lines.count <= 100, let first = lines.first else { throw invalid() }
        let request = first.components(separatedBy: " ")
        guard request.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(request[2]),
              request[0].allSatisfy({ $0.isASCII && $0.isUppercase }), !request[0].isEmpty,
              request[1].hasPrefix("/"), request[1].utf8.count <= 2_048,
              !request[1].contains("%"), !request[1].contains("?"), !request[1].contains("#"),
              !request[1].contains("\\"), !request[1].contains(".."),
              request[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw invalid() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 < 127) }) else { throw invalid() }
            let key = String(line[..<colon]).lowercased(), value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[key] == nil else { throw invalid() }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil, headers["content-length"] == nil || headers["content-length"] == "0" else { throw invalid() }
        return Request(method: request[0], target: request[1], headers: headers)
    }
    static func byteRange(_ header: String?, size: Int64) throws -> ClosedRange<Int64> {
        guard size > 0 else { throw invalid() }
        guard let header else { return 0...(size - 1) }
        guard header.hasPrefix("bytes=") else { throw invalid() }
        let pieces = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { throw invalid() }
        if pieces[0].isEmpty {
            guard let count = Int64(pieces[1]), count > 0 else { throw invalid() }
            return max(0, size - count)...(size - 1)
        }
        guard let start = Int64(pieces[0]), start >= 0, start < size else { throw invalid() }
        let end: Int64
        if pieces[1].isEmpty { end = size - 1 }
        else { guard let number = Int64(pieces[1]), number >= start else { throw invalid() }; end = min(size - 1, number) }
        return start...end
    }
    static func headers(status: Int, length: Int64, type: String, extra: String = "") -> Data {
        let reason = [200: "OK", 206: "Partial Content", 404: "Not Found", 405: "Method Not Allowed", 416: "Range Not Satisfiable", 431: "Request Header Fields Too Large"][status] ?? "Bad Request"
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(length)\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\(extra)\r\n".utf8)
    }
    static func manifest(_ app: LocalAppRecord, baseURL: URL) throws -> Data {
        guard let version = app.bundleVersion, try validateHTTPSBase(baseURL.deletingLastPathComponent()) != nil else { throw invalid() }
        let dictionary: [String: Any] = ["items": [[
            "assets": [["kind": "software-package", "url": baseURL.appendingPathComponent("apps/\(app.id.uuidString).ipa").absoluteString]],
            "metadata": ["bundle-identifier": app.bundleIdentifier, "bundle-version": version, "kind": "software", "title": app.displayName]
        ]]]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }
    static func page(_ apps: [LocalAppRecord], session: LocalAppServerSession) -> String {
        let rows = apps.map { app in
            let installation = session.installURL(for: app).map { "<a class=install href=\"\(escape($0.absoluteString))\">Install on device</a>" } ?? "<span class=muted>\(app.supportsInstallation ? "Install requires HTTPS setup" : "Download only · bundle version unavailable")</span>"
            return """
            <article><div class=icon>\(escape(String(app.displayName.prefix(1)).uppercased()))</div><div class=details><h2>\(escape(app.displayName))</h2><p>\(escape(app.bundleIdentifier))</p><p>\(escape(app.bundleVersion ?? "Version unavailable")) · \(escape(ByteCountFormatter.string(fromByteCount: app.byteCount, countStyle: .file))) · Signed and verified at export</p><div class=actions>\(installation)<a href=\"\(escape(session.downloadURL(for: app).absoluteString))\" download>Download IPA</a></div></div></article>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>LoadSide App Library</title><style>
        :root{color-scheme:light dark;font:17px -apple-system,BlinkMacSystemFont,sans-serif}body{margin:0;background:#10131a;color:#e7edf7}main{max-width:1100px;margin:auto;padding:48px 28px}header{margin-bottom:30px}h1{font-size:40px;letter-spacing:-1px;margin:8px 0}h2{font-size:21px;margin:0 0 8px}p{color:#9eaabd;line-height:1.55;margin:4px 0;overflow-wrap:anywhere}.eyebrow{color:#a6b7ff;font-weight:600;font-size:14px;letter-spacing:1.5px}.notice{padding:18px 22px;background:#202737;border-radius:14px;margin:24px 0;line-height:1.6;color:#c2cbda}.grid{display:grid;gap:18px;grid-template-columns:repeat(auto-fit,minmax(min(100%,460px),1fr))}article{display:flex;gap:18px;border:1px solid #30394b;background:#191f2b;border-radius:20px;padding:24px}.icon{flex-shrink:0;width:54px;height:54px;border-radius:13px;background:#303e73;color:#cad5ff;display:grid;place-items:center;font-size:26px;font-weight:700}.details{min-width:0}.actions{display:flex;flex-wrap:wrap;align-items:center;gap:14px;margin-top:22px}a{color:#b7c5ff;text-decoration:none;font-size:16px;font-weight:600;display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;min-height:44px;padding:11px 16px;border-radius:10px;background:#252f45}a:focus-visible{outline:3px solid #cbd5ff;outline-offset:3px}.install{background:#7790ff;color:#0c1429}.muted{font-size:13px;color:#97a4ba}footer{margin-top:28px;color:#8391a8;font-size:14px;line-height:1.6}@media(max-width:500px){main{padding:30px 18px}article{padding:20px}.icon{display:none}h1{font-size:33px}}
        </style></head><body><main><header><div class=eyebrow>LOADSIDE · LOCAL LIBRARY</div><h1>Your apps, ready to share.</h1><p>\(apps.count) signed \(apps.count == 1 ? "app" : "apps") hosted by your Mac.</p></header><div class=notice>\(session.installEnabled ? "Open this page in Safari on your iPhone or iPad and tap Install on device. Keep LoadSide open while installation completes. App signing, provisioning, and device eligibility still apply; an install link does not verify installation or launch." : "Download apps over your local network. Direct iPhone and iPad installation needs an HTTPS server with a certificate trusted by the device. Select Automatic HTTPS in LoadSide to enable installation links.")</div><section class=grid>\(rows.isEmpty ? "<p>No signed apps have been added to this library yet.</p>" : rows)</section><footer>This private link grants access to the listed apps. Keep it private and stop sharing in LoadSide when finished. The Mac must remain awake and connected. HTTP local links are unencrypted.</footer></main></body></html>
        """
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    private static func invalid() -> LoadSideError { LoadSideError("server.request", "Unsupported local server request.") }
}
