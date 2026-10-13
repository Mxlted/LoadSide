import Foundation
import XCTest
@testable import LoadSideCore

final class InjectionEngineTests: XCTestCase {
    private func inputs(in root: URL, executable: Data = BinaryFixtures.macho(), appName: String = "App.app") throws -> (ipa: URL, deb: URL, output: URL, workspaces: URL) {
        let ipa = root.appendingPathComponent("Source.ipa")
        let deb = root.appendingPathComponent("Tweak.deb")
        let workspaces = root.appendingPathComponent("workspaces")
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: false)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.example.app", "CFBundleExecutable": "App", "CFBundleDisplayName": "Original", "CFBundleVersion": "42"], format: .xml, options: 0)
        try ArchiveFixtures.tar([
            .init(path: "Payload/\(appName)/Info.plist", data: info),
            .init(path: "Payload/\(appName)/App", data: executable),
            .init(path: "Payload/\(appName)/embedded.mobileprovision", data: Data("obsolete profile".utf8)),
            .init(path: "Payload/\(appName)/_CodeSignature/CodeResources", data: Data("obsolete seal".utf8)),
            .init(path: "Payload/\(appName)/CodeResources", type: 50, link: "_CodeSignature/CodeResources")
        ]).write(to: ipa)
        try ArchiveFixtures.deb(data: ArchiveFixtures.tar([
            .init(path: "Library/MobileSubstrate/DynamicLibraries/Tweak.dylib", data: BinaryFixtures.macho(fileType: 6)),
            .init(path: "Library/Application Support/Test/Assets.bundle/icon.txt", data: Data("retained resource".utf8))
        ])).write(to: deb)
        return (ipa, deb, root.appendingPathComponent("Prepared-unsigned.ipa"), workspaces)
    }

    func testCredentialFreeDEBExportIsUnsignedAndPreservesSources() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = try inputs(in: root)
        let originalIPA = try Data(contentsOf: files.ipa), originalDEB = try Data(contentsOf: files.deb)
        let result = try await InjectionEngine().run(.init(ipa: files.ipa, injections: [files.deb], output: files.output, displayName: "Prepared"), workspaceRoot: files.workspaces) { _ in }
        XCTAssertTrue(result.requiresSigning)
        XCTAssertEqual(result.bundleIdentifier, "test.example.app")
        XCTAssertEqual(result.displayName, "Prepared")
        XCTAssertEqual(result.injectedLibraryCount, 1)
        XCTAssertEqual(result.sha256, try IPAExport.sha256(files.output))
        XCTAssertTrue(result.warnings.contains { $0.contains("UNSIGNED") && $0.contains("entitlements") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual(json["requiresSigning"] as? Bool, true)
        let extracted = root.appendingPathComponent("verify")
        try Archive.extract(files.output, to: extracted)
        let app = extracted.appendingPathComponent("Payload/App.app")
        XCTAssertEqual(try MachO.inspect(app.appendingPathComponent("App")).slices[0].dependencies, ["@executable_path/Frameworks/Tweak.dylib"])
        for name in ["_CodeSignature", "CodeResources", "embedded.mobileprovision"] {
            XCTAssertNil(try? app.appendingPathComponent(name).resourceValues(forKeys: [.isSymbolicLinkKey]))
        }
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("Assets.bundle/icon.txt"), encoding: .utf8), "retained resource")
        XCTAssertEqual(try Data(contentsOf: files.ipa), originalIPA)
        XCTAssertEqual(try Data(contentsOf: files.deb), originalDEB)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: files.workspaces.path).isEmpty)
    }

    func testNoInputsAndExistingOutputAreRejectedWithoutWorkspace() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = try inputs(in: root)
        for noInputs in [true, false] {
            if !noInputs { try Data("existing export".utf8).write(to: files.output) }
            do {
                _ = try await InjectionEngine().run(.init(ipa: files.ipa, injections: noInputs ? [] : [files.deb], output: files.output), workspaceRoot: files.workspaces) { _ in }
                XCTFail("Expected request rejection")
            } catch let error as LoadSideError {
                XCTAssertEqual(error.code, noInputs ? "injection.inputs" : "output.exists")
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: files.workspaces.path).isEmpty)
        }
        XCTAssertEqual(try String(contentsOf: files.output, encoding: .utf8), "existing export")
    }

    func testEncryptedAndMalformedCodeFailWithWorkspaceCleanup() async throws {
        for binary in [BinaryFixtures.macho(encrypted: true), Data([0xcf, 0xfa, 0xed, 0xfe])] {
            let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let files = try inputs(in: root, executable: binary)
            do {
                _ = try await InjectionEngine().run(.init(ipa: files.ipa, injections: [files.deb], output: files.output), workspaceRoot: files.workspaces) { _ in }
                XCTFail("Expected unsafe code rejection")
            } catch {
                XCTAssertTrue(error is LoadSideError)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: files.output.path))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: files.workspaces.path).isEmpty)
        }
    }

    func testMaliciousDEBTraversalFailsWithoutExportAndPreservesInput() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = try inputs(in: root)
        let malicious = ArchiveFixtures.deb(data: ArchiveFixtures.tar([.init(path: "../../outside", data: Data("unsafe".utf8))]))
        try malicious.write(to: files.deb)
        do {
            _ = try await InjectionEngine().run(.init(ipa: files.ipa, injections: [files.deb], output: files.output), workspaceRoot: files.workspaces) { _ in }
            XCTFail("Expected traversal rejection")
        } catch let error as LoadSideError {
            XCTAssertEqual(error.code, "archive.traversal")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.output.path))
        XCTAssertEqual(try Data(contentsOf: files.deb), malicious)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: files.workspaces.path).isEmpty)
    }

    func testCancellationAfterExtractionCleansWorkspaceAndLeavesNoOutput() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = try inputs(in: root)
        let task = Task {
            try await InjectionEngine().run(.init(ipa: files.ipa, injections: [files.deb], output: files.output), workspaceRoot: files.workspaces) { event in
                if event.stage == .injecting { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.output.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: files.workspaces.path).isEmpty)
    }

    func testUnsignedDiagnosticTextInFilenameCannotHideMalformedSignature() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let malformed = BinaryFixtures.machoWithMalformedSignature()
        XCTAssertTrue(try MachO.inspect(data: malformed).hasCodeSignature)
        let files = try inputs(in: root, executable: malformed, appName: "not signed at all.app")
        let original = try Data(contentsOf: files.ipa)
        do {
            _ = try await InjectionEngine().run(.init(ipa: files.ipa, injections: [files.deb], output: files.output), workspaceRoot: files.workspaces) { _ in }
            XCTFail("A path must not turn a signature-removal error into an unsigned export")
        } catch let error as LoadSideError {
            XCTAssertEqual(error.code, "injection.removeSignature")
        }
        XCTAssertEqual(try Data(contentsOf: files.ipa), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.output.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: files.workspaces.path).isEmpty)
    }

    func testOutputRaceDoesNotOverwriteAndCleansStaging() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let files = try inputs(in: root)
        let concurrentOutput = Data("concurrent export".utf8)
        do {
            _ = try await InjectionEngine().run(.init(ipa: files.ipa, injections: [files.deb], output: files.output), workspaceRoot: files.workspaces) { event in
                if event.stage == .exporting { try? concurrentOutput.write(to: files.output) }
            }
            XCTFail("Expected exclusive commit rejection")
        } catch let error as LoadSideError {
            XCTAssertEqual(error.code, "output.commit")
        }
        XCTAssertEqual(try Data(contentsOf: files.output), concurrentOutput)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".LoadSide-") })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: files.workspaces.path).isEmpty)
    }

    func testRealSignedAppAndLibraryLoseTheirSignaturesOnlyInExport() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessRunner()
        let selected = try await runner.run("/usr/bin/xcode-select", ["-p"])
        let developer = URL(fileURLWithPath: String(decoding: selected.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        let sdk = developer.appendingPathComponent("Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")
        let clang = developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
        guard FileManager.default.fileExists(atPath: sdk.path), FileManager.default.isExecutableFile(atPath: clang.path) else {
            throw XCTSkip("The full Xcode iOS SDK is required to validate real signature removal.")
        }
        let archive = root.appendingPathComponent("archive"), app = archive.appendingPathComponent("Payload/Real.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let mainSource = root.appendingPathComponent("main.c"), librarySource = root.appendingPathComponent("tweak.c")
        let binary = app.appendingPathComponent("Real"), library = root.appendingPathComponent("RealTweak.dylib")
        try Data("int main(void) { return 0; }\n".utf8).write(to: mainSource)
        try Data("int loadside_fixture(void) { return 42; }\n".utf8).write(to: librarySource)
        let flags = ["-target", "arm64-apple-ios14.0", "-isysroot", sdk.path, "-nostdlib", "-lSystem", "-fno-stack-protector", "-Wl,-headerpad,0x1000"]
        _ = try await runner.run("/usr/bin/env", ["TMPDIR=" + root.path, clang.path] + flags + ["-Wl,-e,_main", mainSource.path, "-o", binary.path])
        _ = try await runner.run("/usr/bin/env", ["TMPDIR=" + root.path, clang.path] + flags + ["-dynamiclib", "-Wl,-install_name,@rpath/RealTweak.dylib", librarySource.path, "-o", library.path])
        let info: [String: Any] = ["CFBundleIdentifier": "test.loadside.real", "CFBundleExecutable": "Real", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        _ = try await runner.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", library.path])
        _ = try await runner.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path])
        let source = root.appendingPathComponent("Signed.ipa"), output = root.appendingPathComponent("Prepared-unsigned.ipa")
        try Archive.createIPA(from: archive, to: source)
        let sourceHash = try IPAExport.sha256(source), libraryHash = try IPAExport.sha256(library)
        let result = try await InjectionEngine().run(.init(ipa: source, injections: [library], output: output)) { _ in }
        XCTAssertTrue(result.requiresSigning)
        let extracted = root.appendingPathComponent("exported")
        try Archive.extract(output, to: extracted)
        for path in ["Payload/Real.app/Real", "Payload/Real.app/Frameworks/RealTweak.dylib"] {
            let display = try await runner.run("/usr/bin/codesign", ["--display", extracted.appendingPathComponent(path).path], check: false)
            XCTAssertNotEqual(display.status, 0)
            XCTAssertTrue(display.diagnostic.contains("not signed at all"))
        }
        _ = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        _ = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", library.path])
        XCTAssertEqual(try IPAExport.sha256(source), sourceHash)
        XCTAssertEqual(try IPAExport.sha256(library), libraryHash)
    }
}
