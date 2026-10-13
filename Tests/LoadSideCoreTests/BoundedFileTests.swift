import Darwin
import XCTest

@testable import LoadSideCore

final class BoundedFileTests: XCTestCase {
    private let invalid = LoadSideError("fixture.invalidFile", "Invalid fixture file.")

    func testReadsExactLimitAcrossChunksWithoutChangingSource() throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input")
        let contents = Data(repeating: 0x5a, count: 128 * 1_024)
        try contents.write(to: file)
        XCTAssertEqual(try BoundedFile.read(file, maximumBytes: contents.count, invalid: invalid), contents)
        XCTAssertEqual(try Data(contentsOf: file), contents)
        XCTAssertThrowsError(try BoundedFile.read(file, maximumBytes: contents.count - 1, invalid: invalid)) {
            XCTAssertEqual(($0 as? LoadSideError)?.code, self.invalid.code)
        }
    }

    func testRejectsSourceReplacedAfterEarlierSizeInspection() throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input")
        try Data([0x5a]).write(to: file)
        let inspectedSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(inspectedSize, 1)
        try Data(repeating: 0x5a, count: 128).write(to: file, options: .atomic)
        XCTAssertThrowsError(try BoundedFile.read(file, maximumBytes: 16, invalid: invalid)) {
            XCTAssertEqual(($0 as? LoadSideError)?.code, self.invalid.code)
        }
    }

    func testRejectsSpecialFilesAndUnrequestedSymbolicLinks() throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input")
        let link = root.appendingPathComponent("link")
        let pipe = root.appendingPathComponent("pipe")
        let contents = Data("fixture".utf8)
        try contents.write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let start = ContinuousClock.now
        for input in [root, link, pipe, URL(string: "https://example.com/input")!] {
            XCTAssertThrowsError(try BoundedFile.read(input, maximumBytes: 128, invalid: invalid)) {
                XCTAssertEqual(($0 as? LoadSideError)?.code, self.invalid.code)
            }
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2), "A FIFO must not wait for a writer.")
        XCTAssertEqual(try BoundedFile.read(link, maximumBytes: 128, followingSymlinks: true, invalid: invalid), contents)
    }

    func testEmptyFilePolicyAndCancellation() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("empty")
        try Data().write(to: file)
        XCTAssertEqual(try BoundedFile.read(file, maximumBytes: 128, invalid: invalid), Data())
        XCTAssertThrowsError(try BoundedFile.read(file, maximumBytes: 128, minimumBytes: 1, invalid: invalid))
        let invalid = self.invalid
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BoundedFile.read(file, maximumBytes: 128, invalid: invalid)
        }
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled read must fail before accessing the file.")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
