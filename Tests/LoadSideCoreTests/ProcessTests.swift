import XCTest
@testable import LoadSideCore

final class ProcessTests: XCTestCase {
    func testCapturesStdoutAndNonzeroExit() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run("/usr/bin/printf", ["%s", "literal $(never executed)"])
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "literal $(never executed)")
        do { _ = try await runner.run("/usr/bin/false", []); XCTFail("Expected nonzero status") }
        catch { XCTAssertEqual((error as? LoadSideError)?.code, "tool.failed") }
    }

    func testTimeoutKillsChild() async throws {
        let start = ContinuousClock.now
        do { _ = try await ProcessRunner().run("/bin/sleep", ["20"], timeout: 0.1); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? LoadSideError)?.code, "tool.timeout") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testCancellationKillsChild() async throws {
        let child = Task { try await ProcessRunner().run("/bin/sleep", ["20"]) }
        try await Task.sleep(for: .milliseconds(100))
        child.cancel()
        do { _ = try await child.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testOutputLimit() async throws {
        do { _ = try await ProcessRunner().run("/usr/bin/printf", ["%s", String(repeating: "a", count: 500)], maximumOutput: 100); XCTFail("Expected bounded output") }
        catch { XCTAssertEqual((error as? LoadSideError)?.code, "tool.outputLimit") }
    }
}
