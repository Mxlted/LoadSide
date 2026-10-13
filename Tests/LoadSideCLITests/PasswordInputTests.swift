import Darwin
import Foundation
import LoadSideCore
import XCTest

@testable import LoadSideCLI

final class PasswordInputTests: XCTestCase {
    func testFileInputPreservesWhitespaceAndStripsOnlyOneLineEnding() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("password")
        let cases = [
            ("", ""),
            ("\n", ""),
            ("\r\n", ""),
            ("  secret  \r\n", "  secret  "),
            ("secret\n\n", "secret\n"),
            ("secret\r\n\r\n", "secret\r\n"),
            ("secret\r", "secret\r"),
            ("e\u{301}\r\n", "e\u{301}"),
            ("👩🏽‍💻\r\n", "👩🏽‍💻"),
            ("👩🏽‍💻\n", "👩🏽‍💻")
        ]
        for (input, expected) in cases {
            try writePrivate(Data(input.utf8), to: url)
            let actual = try PasswordInput.readFile(at: url)
            XCTAssertEqual(Array(actual.utf8), Array(expected.utf8))
        }
    }

    func testFileSizeAndUTF8AreValidatedWithoutReturningContentsInErrors() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("password")
        let maximum = Data(repeating: 0x61, count: 16_384)
        try writePrivate(maximum, to: url)
        XCTAssertEqual(try PasswordInput.readFile(at: url).utf8.count, maximum.count)
        for invalid in [Data(repeating: 0x61, count: 16_385), Data([0xff])] {
            try writePrivate(invalid, to: url)
            XCTAssertThrowsError(try PasswordInput.readFile(at: url)) { error in
                XCTAssertEqual((error as? LoadSideError)?.code, "credentials.password")
            }
        }
    }

    func testGroupReadablePasswordFileIsRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("password")
        try writePrivate(Data("secret".utf8), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        XCTAssertThrowsError(try PasswordInput.readFile(at: url)) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "credentials.permissions")
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testLinksDirectoriesAndNamedPipesAreRejected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let link = root.appendingPathComponent("link")
        let pipe = root.appendingPathComponent("pipe")
        try writePrivate(Data("secret".utf8), to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        for url in [link, root, pipe] {
            XCTAssertThrowsError(try PasswordInput.readFile(at: url)) { error in
                XCTAssertEqual((error as? LoadSideError)?.code, "credentials.password")
            }
        }
        XCTAssertEqual(try Data(contentsOf: original), Data("secret".utf8))
    }

    func testConflictingInputMethodsAreRejectedBeforeReading() throws {
        let options = try CommandOptions(["--password-stdin", "--password-file", "not-opened"])
        XCTAssertThrowsError(try PasswordInput.read(options)) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "arguments.password")
        }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
