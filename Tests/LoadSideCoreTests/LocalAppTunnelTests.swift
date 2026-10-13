import Foundation
import Darwin
import XCTest
@testable import LoadSideCore

final class LocalAppTunnelTests: XCTestCase {
    func testOutputWaitsForCompleteRecordsAndRegisteredConnection() throws {
        var output = LocalTunnelOutput()
        try output.consume(Data("{\"level\":\"info\",\"message\":\"| https://quiet-safe-fixture.trycloudflare.com |\"".utf8))
        XCTAssertNil(output.url)
        try output.consume(Data("}\n{\"level\":\"info\",\"message\":\"Registered tunnel ".utf8))
        XCTAssertEqual(output.url?.absoluteString, "https://quiet-safe-fixture.trycloudflare.com")
        XCTAssertFalse(output.registered)
        try output.consume(Data("connection\",\"connIndex\":0}\n".utf8))
        XCTAssertTrue(output.registered)
    }

    func testOutputRejectsUnexpectedHostsCredentialsPathsAndMalformedRecords() throws {
        for address in ["http://safe.trycloudflare.com", "https://safe.trycloudflare.com.attacker.example",
                        "https://user@safe.trycloudflare.com", "https://safe.trycloudflare.com:443",
                        "https://safe.trycloudflare.com/path", "https://safe.trycloudflare.com?token=secret",
                        "https://safe.trycloudflare.com#fragment", "https://nested.safe.trycloudflare.com",
                        "https://-invalid.trycloudflare.com", "https://invalid-.trycloudflare.com",
                        "https://invalid_name.trycloudflare.com", "https://安全.trycloudflare.com"] {
            var output = LocalTunnelOutput()
            try output.consume(Data("| \(address) |\n".utf8))
            XCTAssertNil(output.url, address)
        }
        var malformed = LocalTunnelOutput()
        try malformed.consume(Data("{\"message\":\"https://safe.trycloudflare.com\"\n".utf8))
        try malformed.consume(Data("{\"level\":\"error\",\"message\":\"Registered tunnel connection\"}\n".utf8))
        XCTAssertNil(malformed.url)
        XCTAssertFalse(malformed.registered)
        XCTAssertThrowsError(try malformed.consume(Data(repeating: 65, count: 16_385)))
    }

    func testTrustedSyntheticHelperStartsInPrivateWorkspaceAndStopReapsIt() async throws {
        let fixture = try TunnelFixture(ready: true)
        defer { fixture.remove() }
        let tunnel = LocalAppTunnel(startupTimeout: .seconds(3))
        let url = try await tunnel.start(executable: fixture.executable, port: 8787)
        XCTAssertEqual(url.absoluteString, "https://quiet-safe-fixture.trycloudflare.com")
        let state = try fixture.state()
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: state.directory)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertNotEqual(kill(state.pid, 0), -1)
        await tunnel.stop()
        XCTAssertEqual(kill(state.pid, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.directory))
        await tunnel.stop()
    }

    func testEarlyExitSuppressesRawDiagnosticsAndCleansWorkspace() async throws {
        let fixture = try TunnelFixture(ready: false, ending: "printf 'SECRET_DIAGNOSTIC_FROM_HELPER\\n' >&2\nexit 9")
        defer { fixture.remove() }
        let tunnel = LocalAppTunnel(startupTimeout: .seconds(2))
        do { _ = try await tunnel.start(executable: fixture.executable, port: 8787); XCTFail("Accepted a failed helper") }
        catch {
            XCTAssertEqual((error as? LoadSideError)?.code, "tunnel.exited")
            XCTAssertFalse(error.localizedDescription.contains("SECRET_DIAGNOSTIC"))
        }
        let state = try fixture.state()
        XCTAssertEqual(kill(state.pid, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.directory))
    }

    func testTimeoutRequiresBothURLAndRegistrationAndReapsChild() async throws {
        let fixture = try TunnelFixture(ready: false, extra: "printf '%s\\n' '| https://quiet-safe-fixture.trycloudflare.com |'")
        defer { fixture.remove() }
        let tunnel = LocalAppTunnel(startupTimeout: .milliseconds(200))
        do { _ = try await tunnel.start(executable: fixture.executable, port: 8787); XCTFail("Accepted an unconnected URL") }
        catch { XCTAssertEqual((error as? LoadSideError)?.code, "tunnel.timeout") }
        let state = try fixture.state()
        XCTAssertEqual(kill(state.pid, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.directory))
    }

    func testCancellationReapsChildAndRemovesWorkspace() async throws {
        let fixture = try TunnelFixture(ready: false)
        defer { fixture.remove() }
        let tunnel = LocalAppTunnel(startupTimeout: .seconds(5))
        let pending = Task { try await tunnel.start(executable: fixture.executable, port: 8787) }
        try await fixture.waitUntilStarted()
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let state = try fixture.state()
        XCTAssertEqual(kill(state.pid, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.directory))
    }

    func testStoppedStartupCannotStopNewGeneration() async throws {
        let first = try TunnelFixture(ready: false), second = try TunnelFixture(ready: true)
        defer { first.remove(); second.remove() }
        let tunnel = LocalAppTunnel(startupTimeout: .seconds(3))
        let pending = Task { try await tunnel.start(executable: first.executable, port: 8787) }
        try await first.waitUntilStarted()
        await tunnel.stop()
        _ = try await tunnel.start(executable: second.executable, port: 8787)
        do { _ = try await pending.value; XCTFail("Expected old startup cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let secondState = try second.state()
        XCTAssertNotEqual(kill(secondState.pid, 0), -1)
        await tunnel.stop()
        XCTAssertEqual(kill(secondState.pid, 0), -1)
    }

    func testUnexpectedExitNotifiesAndCleansWorkspace() async throws {
        let fixture = try TunnelFixture(ready: true, ending: "/bin/sleep 0.3\nexit 7")
        defer { fixture.remove() }
        let failures = TunnelFailures()
        let tunnel = LocalAppTunnel(startupTimeout: .seconds(2), onFailure: { failures.append($0) })
        _ = try await tunnel.start(executable: fixture.executable, port: 8787)
        let state = try fixture.state(), began = ContinuousClock.now
        while failures.count == 0, began.duration(to: .now) < .seconds(3) { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(kill(state.pid, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.directory))
        await tunnel.stop()
        XCTAssertEqual(failures.count, 1)
    }

    func testConcurrentStopsAwaitInFlightCleanupWithoutStoppingNewGeneration() async throws {
        let first = try TunnelFixture(ready: true), second = try TunnelFixture(ready: true)
        defer { first.remove(); second.remove() }
        let tunnel = LocalAppTunnel(startupTimeout: .seconds(3), terminationNotificationDelay: .milliseconds(400))
        _ = try await tunnel.start(executable: first.executable, port: 8787)
        let firstState = try first.state(), completions = TunnelFailures()
        let firstStop = Task { await tunnel.stop(); completions.append("first") }
        let began = ContinuousClock.now
        while kill(firstState.pid, 0) == 0, began.duration(to: .now) < .seconds(2) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(kill(firstState.pid, 0), -1)
        let secondStop = Task { await tunnel.stop(); completions.append("second") }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(completions.count, 0, "A concurrent stop returned while old cleanup was still pending")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstState.directory))
        _ = try await tunnel.start(executable: second.executable, port: 8787)
        let secondState = try second.state()
        await firstStop.value; await secondStop.value
        XCTAssertEqual(completions.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstState.directory))
        XCTAssertNotEqual(kill(secondState.pid, 0), -1, "An older stop killed the newly started helper")
        await tunnel.stop()
        XCTAssertEqual(kill(secondState.pid, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondState.directory))
    }

    func testDiagnosticFloodIsBoundedAndChildIsCleaned() async throws {
        let fixture = try TunnelFixture(ready: false, extra: "/usr/bin/head -c 2100000 /dev/zero")
        defer { fixture.remove() }
        let tunnel = LocalAppTunnel(startupTimeout: .seconds(3))
        do { _ = try await tunnel.start(executable: fixture.executable, port: 8787); XCTFail("Accepted diagnostic flood") }
        catch { XCTAssertEqual((error as? LoadSideError)?.code, "tunnel.outputLimit") }
        let state = try fixture.state()
        XCTAssertEqual(kill(state.pid, 0), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.directory))
    }
}

private struct TunnelFixture {
    let root: URL
    let executable: URL

    init(ready: Bool, extra: String = "", ending: String = "exec /bin/sleep 20") throws {
        root = try BinaryFixtures.temporaryDirectory()
        executable = root.appendingPathComponent("synthetic-tunnel")
        // A test-owned script records only its synthetic PID/workspace. It also asserts that
        // configuration cannot leak in from the user's ordinary cloudflared environment.
        let script = """
        #!/bin/sh
        set -eu
        [ "$HOME" -ef . ]
        [ "$TMPDIR" -ef . ]
        [ "$1" = "tunnel" ]
        [ "$2" = "--config" ]
        [ -f "$3" ]
        [ "$4" = "--no-autoupdate" ]
        [ "$5" = "--url" ]
        [ "$6" = "http://127.0.0.1:8787" ]
        [ "$7" = "--protocol" ]
        [ "$8" = "http2" ]
        printf '%s\\n%s\\n' "$PWD" "$$" > "$0.state"
        \(extra)
        \(ready ? "printf '%s\\n' '{\"level\":\"info\",\"message\":\"| https://quiet-safe-fixture.trycloudflare.com |\"}' '{\"level\":\"info\",\"message\":\"Registered tunnel connection\",\"connIndex\":0}'" : "")
        \(ending)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func state() throws -> (directory: String, pid: Int32) {
        let lines = try String(contentsOf: executable.appendingPathExtension("state"), encoding: .utf8).split(separator: "\n")
        return (String(lines[0]), try XCTUnwrap(Int32(lines[1])))
    }

    func waitUntilStarted() async throws {
        let began = ContinuousClock.now
        while !FileManager.default.fileExists(atPath: executable.appendingPathExtension("state").path) {
            if began.duration(to: .now) > .seconds(3) { throw LoadSideError("fixture.timeout", "The synthetic helper did not start.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class TunnelFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var count: Int { lock.withLock { messages.count } }
    func append(_ message: String) { lock.withLock { messages.append(message) } }
}
