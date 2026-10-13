import Foundation
import LoadSideCore
import XCTest

@testable import LoadSideApp

final class JobHistoryStoreTests: XCTestCase {
    func testLegacyRecordsDecodeAndOnlyRunningJobsBecomeInterrupted() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobHistoryStore(url: root.appendingPathComponent("history.json"))
        let records: [[String: Any]] = ["running", "completed", "failed", "cancelled"].map { status in
            [
                "id": UUID().uuidString,
                "startedAt": 123.0,
                "sourceName": "Legacy.ipa",
                "status": status,
                "output": "file:///tmp/Legacy-signed.ipa",
                "events": [],
                "entitlementPolicy": "strict",
                "profileCount": 1,
                "injectionNames": []
            ]
        }
        try JSONSerialization.data(withJSONObject: records).write(to: store.url)

        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.status), [.interrupted, .completed, .failed, .cancelled])
        XCTAssertEqual(loaded.first?.startedAt, Date(timeIntervalSinceReferenceDate: 123))
        XCTAssertEqual(loaded.first?.sourceName, "Legacy.ipa")
        XCTAssertNil(loaded.first?.jobMode)
        XCTAssertNil(loaded.first?.extensionProfilePolicy)
        XCTAssertNil(loaded.first?.savedSigningProfileID)
        XCTAssertNil(loaded.first?.injectionResult)
        XCTAssertNotNil(loaded.first?.failure)
        XCTAssertNotNil(loaded.first?.recovery)
        XCTAssertNil(loaded.first?.finishedAt)
        XCTAssertNil(loaded[1].failure)
        XCTAssertNil(loaded[1].recovery)
    }

    func testSavePreservesRecordAndEventIdentityWithPrivatePermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobHistoryStore(url: root.appendingPathComponent("private/history.json"))
        let event = SigningEvent(stage: .exporting, fraction: 0.9, message: "Exporting archive")
        let record = JobRecord(
            id: UUID(), startedAt: Date(), sourceName: "Example.ipa", status: .completed,
            output: root.appendingPathComponent("Example.ipa"), events: [event],
            entitlementPolicy: .strict, profileCount: 1, injectionNames: [],
            removeExtensions: false, bundleIdentifierPolicy: .preserve,
            extensionProfilePolicy: .reuseMain, jobMode: .sign
        )
        try store.save([record])
        let loaded = try XCTUnwrap(store.load().first)

        XCTAssertEqual(loaded.id, record.id)
        XCTAssertEqual(loaded.status, record.status)
        XCTAssertEqual(loaded.jobMode, .sign)
        XCTAssertEqual(loaded.extensionProfilePolicy, .reuseMain)
        XCTAssertEqual(loaded.events.first?.id, event.id)
        XCTAssertEqual(loaded.events.first?.date, event.date)
        XCTAssertEqual(loaded.events.first?.message, event.message)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: store.url.deletingLastPathComponent().path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMissingHistoryIsEmptyAndMalformedHistoryIsPreserved() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobHistoryStore(url: root.appendingPathComponent("history.json"))
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        let malformed = Data("{invalid".utf8)
        try malformed.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), malformed)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
