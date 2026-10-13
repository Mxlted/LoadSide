import Foundation

/// Bounded HTTP parsing and presentation for the local, capability-scoped app catalog.
enum LocalHTTP {
    static let maximumHeaderBytes = 16 * 1_024
    struct Request { let method: String; let target: String; let headers: [String: String] }
    enum Route: Equatable {
        case catalog
        case manifest(UUID)
        case archive(UUID)
    }

    /// Routes use literal, canonical UUID paths under the current session's capability URL.
    /// Encoded paths, query strings, and traversal are rejected by `parse` before routing.
    static func route(_ target: String, localURL: URL) -> Route? {
        let prefix = localURL.path.hasSuffix("/") ? localURL.path : localURL.path + "/"
        guard target.hasPrefix(prefix) else { return nil }
        let relative = String(target.dropFirst(prefix.count))
        guard !relative.isEmpty else { return .catalog }

        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "apps" else { return nil }
        let name = String(parts[1])
        let isManifest = name.hasSuffix(".plist")
        let suffix = isManifest ? ".plist" : ".ipa"
        guard name.hasSuffix(suffix),
              let id = UUID(uuidString: String(name.dropLast(suffix.count))),
              name == id.uuidString + suffix else { return nil }
        return isManifest ? .manifest(id) : .archive(id)
    }

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
        let terminator = Data("\r\n\r\n".utf8)
        guard data.count <= maximumHeaderBytes, data.suffix(terminator.count) == terminator,
              let string = String(data: data.dropLast(terminator.count), encoding: .ascii) else { throw invalid() }
        // HTTP framing counts bytes. Swift treats each CRLF pair as one Character, so
        // trimming four Characters would also remove two bytes from the final header.
        let lines = string.components(separatedBy: "\r\n")
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
