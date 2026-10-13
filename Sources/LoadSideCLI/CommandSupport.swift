import Darwin
import Foundation
import LoadSideCore

/// Shared execution and reporting keep signing and unsigned injection consistent.
enum CommandSupport {
    static func run<Output: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        let task = Task(operation: operation)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        interrupt.setEventHandler { task.cancel() }
        terminate.setEventHandler { task.cancel() }
        interrupt.resume()
        terminate.resume()
        defer {
            interrupt.cancel()
            terminate.cancel()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func report(_ event: SigningEvent, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(event) {
                LoadSideCLI.writeError(String(decoding: data, as: UTF8.self) + "\n")
            }
        } else {
            LoadSideCLI.writeError("[\(Int(event.fraction * 100))%] \(event.stage.title): \(event.message)\n")
        }
    }

    static func printJSON(_ result: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }
}
