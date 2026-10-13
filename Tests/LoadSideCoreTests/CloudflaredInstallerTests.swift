import CryptoKit
import Foundation
import XCTest

@testable import LoadSideCore

final class CloudflaredInstallerTests: XCTestCase {
    func testPinnedReleaseUsesOnlyOfficialARM64Archive() {
        XCTAssertEqual(
            CloudflaredInstaller.Release.pinned.archiveURL.absoluteString,
            "https://github.com/cloudflare/cloudflared/releases/download/\(CloudflaredInstaller.version)/cloudflared-darwin-arm64.tgz")
        XCTAssertTrue(CloudflaredInstaller.allowedDownloadURL(CloudflaredInstaller.Release.pinned.archiveURL))
        XCTAssertEqual(CloudflaredInstaller.Release.pinned.minimumMacOSMajor, 15)
    }

    func testUnsupportedHelperOSFailsBeforeStorageOrDownload() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("tools")
        let calls = DownloadCounter()
        let installer = CloudflaredInstaller(directory: directory, release: .pinned, macOSMajorVersion: 14) { _, _, _ in
            await calls.record()
        }
        do {
            _ = try await installer.executable()
            XCTFail("Prepared an incompatible helper")
        } catch let error as LoadSideError {
            XCTAssertEqual(error.code, "https.helper")
            XCTAssertTrue(error.message.contains("macOS 15"))
            XCTAssertTrue(error.message.contains("Local downloads only"))
            XCTAssertTrue(error.message.contains("My HTTPS server"))
            XCTAssertTrue(error.recovery.contains("Local downloads only"))
            XCTAssertTrue(error.recovery.contains("My HTTPS server"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }

    func testCompatibleHelperInstallsAtItsMinimumOSVersion() async throws {
        for minimum in [14, 15] {
            let root = try BinaryFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = helperFixture(minimumMacOSMajor: minimum)
            let directory = root.appendingPathComponent("tools")
            let installer = CloudflaredInstaller(directory: directory, release: fixture.release, macOSMajorVersion: minimum) {
                _, target, _ in
                try fixture.archive.write(to: target)
            }
            let executable = try await installer.executable()
            XCTAssertEqual(try Data(contentsOf: executable), fixture.binary)
        }
    }

    func testInstallsPinnedExecutablePrivatelyAndReusesOnlyVerifiedCopy() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = helperFixture()
        let calls = DownloadCounter()
        let directory = root.appendingPathComponent("tools")
        let installer = CloudflaredInstaller(directory: directory, release: fixture.release) { source, target, limit in
            XCTAssertEqual(source, fixture.release.archiveURL)
            XCTAssertEqual(limit, Int64(fixture.archive.count))
            await calls.record()
            try fixture.archive.write(to: target)
        }
        let executable = try await installer.executable()
        XCTAssertEqual(try Data(contentsOf: executable), fixture.binary)
        XCTAssertEqual(executable.lastPathComponent, "cloudflared-\(CloudflaredInstaller.version)-arm64")
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(executable), 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [executable.lastPathComponent])
        let reused = try await installer.executable()
        XCTAssertEqual(reused, executable)
        let count = await calls.count
        XCTAssertEqual(count, 1)
        try Data(repeating: 0, count: fixture.binary.count).write(to: executable)
        do {
            _ = try await installer.executable()
            XCTFail("Reused modified helper")
        } catch {}
        let afterTampering = await calls.count
        XCTAssertEqual(afterTampering, 1, "An unexpected existing file must not be silently replaced")
    }

    func testBadDownloadChecksumOrLengthNeverInstallsAndCleansStaging() async throws {
        for excessiveLength in [false, true] {
            let root = try BinaryFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = helperFixture()
            let directory = root.appendingPathComponent("tools")
            let installer = CloudflaredInstaller(directory: directory, release: fixture.release) { _, target, _ in
                try Data(repeating: 0, count: fixture.archive.count + (excessiveLength ? 1 : 0)).write(to: target)
            }
            do {
                _ = try await installer.executable()
                XCTFail("Installed unverified download")
            } catch {}
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    func testVerifiesEveryChunkAndPartialFinalChunkOfCachedHelper() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = Data((0..<(2 * 64 * 1_024 + 17)).map { UInt8(truncatingIfNeeded: $0) })
        let fixture = helperFixture(binary: binary)
        let directory = root.appendingPathComponent("tools")
        let installer = fixtureInstaller(fixture, at: directory)
        let executable = try await installer.executable()
        XCTAssertEqual(try Data(contentsOf: executable), binary)
        let reused = try await installer.executable()
        XCTAssertEqual(reused, executable)

        for index in [0, 64 * 1_024, binary.count - 1] {
            var modified = binary
            modified[index] ^= 0xff
            try modified.write(to: executable)
            do {
                _ = try await installer.executable()
                XCTFail("Accepted a changed byte at offset \(index)")
            } catch let error as LoadSideError {
                XCTAssertEqual(error.code, "https.helper")
                XCTAssertTrue(error.message.contains("integrity check"))
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [executable.lastPathComponent])
    }

    func testAlreadyCancelledInstallDoesNotCreateStorageOrDownload() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = helperFixture()
        let directory = root.appendingPathComponent("tools")
        let calls = DownloadCounter()
        let installer = CloudflaredInstaller(directory: directory, release: fixture.release) { _, target, _ in
            await calls.record()
            try fixture.archive.write(to: target)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await installer.executable()
        }
        do {
            _ = try await task.value
            XCTFail("Prepared a helper for an already cancelled operation")
        } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }

    func testWrongExecutableChecksumIsRejectedEvenWithValidArchiveChecksum() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = helperFixture(binaryDigest: String(repeating: "0", count: 64))
        let directory = root.appendingPathComponent("tools")
        let installer = fixtureInstaller(fixture, at: directory)
        do {
            _ = try await installer.executable()
            XCTFail("Installed unexpected executable")
        } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testUnexpectedArchiveEntriesLinksAndTraversalAreRejected() async throws {
        let binary = Data("fixture helper".utf8)
        let cases: [[ArchiveFixtures.Entry]] = [
            [.init(path: "cloudflared", data: binary), .init(path: "extra", data: Data())],
            [.init(path: "other-name", data: binary)],
            [.init(path: "../cloudflared", data: binary)],
            [.init(path: "cloudflared", type: 50, link: "elsewhere")],
            [.init(path: "cloudflared", type: 49, link: "elsewhere")],
            [.init(path: "cloudflared", type: 51)]
        ]
        for entries in cases {
            let root = try BinaryFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = helperFixture(entries: entries)
            let directory = root.appendingPathComponent("tools")
            do {
                _ = try await fixtureInstaller(fixture, at: directory).executable()
                XCTFail("Installed unsafe archive")
            } catch {}
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cloudflared").path))
        }
    }

    func testSymlinkStorageAndExistingSymlinkOrHardLinkAreRejected() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = helperFixture()
        let real = root.appendingPathComponent("real")
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        do {
            _ = try await fixtureInstaller(fixture, at: linked).executable()
            XCTFail("Followed helper directory symlink")
        } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)

        let source = root.appendingPathComponent("original")
        try fixture.binary.write(to: source)
        let destination = real.appendingPathComponent("cloudflared-\(CloudflaredInstaller.version)-arm64")
        for hardLink in [false, true] {
            if hardLink {
                try FileManager.default.linkItem(at: source, to: destination)
            } else {
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
            }
            do {
                _ = try await fixtureInstaller(fixture, at: real).executable()
                XCTFail("Used linked executable")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: source), fixture.binary)
            try FileManager.default.removeItem(at: destination)
        }
    }

    func testCancellationDuringDownloadLeavesNoInstalledOrPartialHelper() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = helperFixture()
        let directory = root.appendingPathComponent("tools")
        let started = DownloadSignal()
        let installer = CloudflaredInstaller(directory: directory, release: fixture.release) { _, target, _ in
            try Data("partial".utf8).write(to: target)
            await started.send()
            try await Task.sleep(for: .seconds(30))
        }
        let task = Task { try await installer.executable() }
        await started.wait()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Ignored setup cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let executable = try await fixtureInstaller(fixture, at: directory).executable()
        XCTAssertEqual(try Data(contentsOf: executable), fixture.binary)
    }

    func testDownloadFailureCleansStagingAndHidesRawError() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = helperFixture()
        let directory = root.appendingPathComponent("tools")
        let installer = CloudflaredInstaller(directory: directory, release: fixture.release) { _, target, _ in
            try Data("partial".utf8).write(to: target)
            throw NSError(domain: "private diagnostic value", code: 1)
        }
        do {
            _ = try await installer.executable()
            XCTFail("Ignored download failure")
        } catch let error as LoadSideError { XCTAssertFalse(error.message.contains("private diagnostic value")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testRedirectPolicyAcceptsOnlyOfficialHTTPSHostsWithoutCredentials() {
        for url in [
            "https://github.com/cloudflare/cloudflared", "https://release-assets.githubusercontent.com/file",
            "https://objects.githubusercontent.com/file"
        ] {
            XCTAssertTrue(CloudflaredInstaller.allowedDownloadURL(URL(string: url)))
        }
        for url in [
            "http://github.com/file", "https://github.com.attacker.example/file", "https://user:password@github.com/file",
            "https://github.com:8443/file", "file:///tmp/file"
        ] {
            XCTAssertFalse(CloudflaredInstaller.allowedDownloadURL(URL(string: url)))
        }
        XCTAssertFalse(CloudflaredInstaller.allowedDownloadURL(nil))
    }

    private func permissions(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }
}

private struct HelperFixture: Sendable {
    let archive: Data
    let binary: Data
    let release: CloudflaredInstaller.Release
}

private func helperFixture(
    binary: Data = Data("fixture helper".utf8), entries: [ArchiveFixtures.Entry]? = nil, binaryDigest: String? = nil,
    minimumMacOSMajor: Int = 14
) -> HelperFixture {
    let archive = ArchiveFixtures.tar(entries ?? [.init(path: "cloudflared", data: binary)])
    let release = CloudflaredInstaller.Release(
        archiveSHA256: helperDigest(archive),
        executableSHA256: binaryDigest ?? helperDigest(binary), archiveBytes: Int64(archive.count), executableBytes: Int64(binary.count),
        minimumMacOSMajor: minimumMacOSMajor)
    return HelperFixture(archive: archive, binary: binary, release: release)
}

private func fixtureInstaller(_ fixture: HelperFixture, at directory: URL) -> CloudflaredInstaller {
    CloudflaredInstaller(directory: directory, release: fixture.release) { _, target, _ in try fixture.archive.write(to: target) }
}

private func helperDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private actor DownloadCounter {
    var count = 0
    func record() { count += 1 }
}
private actor DownloadSignal {
    var sent = false
    var waiter: CheckedContinuation<Void, Never>?
    func send() {
        sent = true
        waiter?.resume()
        waiter = nil
    }
    func wait() async {
        if sent { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
