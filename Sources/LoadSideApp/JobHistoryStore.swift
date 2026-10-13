import Foundation

/// Persists the app's activity records without changing their legacy JSON format.
struct JobHistoryStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? URL.applicationSupportDirectory
            .appendingPathComponent("LoadSide", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    func load() throws -> [JobRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        var history = try JSONDecoder().decode([JobRecord].self, from: Data(contentsOf: url))
        // A process restart cannot resume an in-flight engine operation.
        for index in history.indices where history[index].status == .running {
            history[index].status = .interrupted
            history[index].failure = "LoadSide closed before this job finished."
            history[index].recovery = "Start a new signing session. Any existing export should be treated as unverified."
        }
        return history
    }

    func save(_ history: [JobRecord]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(history).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
