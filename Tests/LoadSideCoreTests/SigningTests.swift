import XCTest

@testable import LoadSideCore

final class SigningTests: XCTestCase {
    func testUnsignedDiagnosticTextInFilenameCannotHideUnreadableEntitlements() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ipa = root.appendingPathComponent("Source.ipa")
        let certificate = root.appendingPathComponent("Unused.p12")
        let profile = root.appendingPathComponent("Unused.mobileprovision")
        let output = root.appendingPathComponent("Signed.ipa")
        let malformed = BinaryFixtures.machoWithMalformedSignature()
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "test.example.app", "CFBundleExecutable": "App"
            ], format: .xml, options: 0)
        let archive = ArchiveFixtures.tar([
            .init(path: "Payload/not signed at all.app/Info.plist", data: info),
            .init(path: "Payload/not signed at all.app/App", data: malformed)
        ])
        try archive.write(to: ipa)
        // Entitlement inspection must fail before either credential is parsed.
        try Data("unused credential".utf8).write(to: certificate)
        try Data("unused profile".utf8).write(to: profile)
        XCTAssertTrue(try MachO.inspect(data: malformed).hasCodeSignature)

        do {
            _ = try await SigningEngine().run(.init(ipa: ipa, certificate: certificate, password: "", profiles: [profile], output: output))
            { _ in }
            XCTFail("An app filename must not turn an entitlement-reading failure into an unsigned app")
        } catch let error as LoadSideError {
            XCTAssertEqual(error.code, "entitlements.read")
        }
        XCTAssertEqual(try Data(contentsOf: ipa), archive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testMainAppStillRejectsMalformedAppsAndMetadataNamedDirectoriesOrLinks() throws {
        for kind in ["file", "directory", "symlink"] {
            let root = try BinaryFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let payload = root.appendingPathComponent("Payload")
            try FileManager.default.createDirectory(at: payload.appendingPathComponent("Source.app"), withIntermediateDirectories: true)
            switch kind {
            case "file":
                try Data("not an app".utf8).write(to: payload.appendingPathComponent("Malformed.app"))
            case "directory":
                try FileManager.default.createDirectory(
                    at: payload.appendingPathComponent("._Source.app"), withIntermediateDirectories: false)
            default:
                try FileManager.default.createSymbolicLink(
                    atPath: payload.appendingPathComponent("._Source.app").path, withDestinationPath: "Source.app")
            }
            XCTAssertThrowsError(try BundleInventory.mainApp(in: root), kind) { error in
                XCTAssertEqual((error as? LoadSideError)?.code, "ipa.payload")
            }
        }
    }

    func testAtomicCommitRefusesExistingDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("existing.ipa")
        let staging = directory.appendingPathComponent("new.ipa")
        try Data("original".utf8).write(to: existing)
        try Data("new".utf8).write(to: staging)
        XCTAssertThrowsError(try IPAExport.commit(staging: staging, destination: existing))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
        let final = directory.appendingPathComponent("export.ipa")
        try IPAExport.commit(staging: staging, destination: final)
        XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testNativeCodesignAndTamperDetection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("echo")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: binary)
        let runner = ProcessRunner()
        _ = try await runner.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", binary.path])
        _ = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", binary.path])
        let handle = try FileHandle(forWritingTo: binary)
        try handle.seek(toOffset: 4096)
        try handle.write(contentsOf: Data(repeating: 0x42, count: 128))
        try handle.close()
        let result = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", binary.path], check: false)
        XCTAssertNotEqual(result.status, 0)
    }

    func testBundleIdentifierRewritesWatchReferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Watch.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.old.main.watch", "WKCompanionAppBundleIdentifier": "com.old.main",
            "NSExtension": ["NSExtensionAttributes": ["WKAppBundleIdentifier": "com.old.main.watch"]]
        ]
        let bundle = CodeBundle(url: app, executable: app.appendingPathComponent("binary"), identifier: "com.old.main.watch", info: info)
        try BundleInventory.rewriteIdentifiers(in: [bundle], original: "com.old.main", replacement: "com.new.main")
        let output = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil)
                as? [String: Any])
        XCTAssertEqual(output["CFBundleIdentifier"] as? String, "com.new.main.watch")
        XCTAssertEqual(output["WKCompanionAppBundleIdentifier"] as? String, "com.new.main")
    }

    func testNestedCodeIsSignedInsideOutAndSurvivesArchiveRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tree = directory.appendingPathComponent("tree")
        let app = tree.appendingPathComponent("Payload/Fixture.app")
        let widget = app.appendingPathComponent("PlugIns/Widget.appex")
        for (url, name, type) in [(app, "Fixture", "APPL"), (widget, "Widget", "XPC!")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: url.appendingPathComponent(name))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.appendingPathComponent(name).path)
            try BundleInventory.writeInfo(
                [
                    "CFBundleIdentifier": "com.example.fixture.\(name)", "CFBundleExecutable": name,
                    "CFBundlePackageType": type, "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"
                ], to: url)
        }
        let resource = widget.appendingPathComponent("sealed.txt")
        try Data("original".utf8).write(to: resource)
        let localizedResources = app.appendingPathComponent("Localization.bundle")
        try FileManager.default.createDirectory(at: localizedResources, withIntermediateDirectories: false)
        try BundleInventory.writeInfo(
            ["CFBundleIdentifier": "com.example.localization", "CFBundleExecutable": "Localization", "CFBundlePackageType": "BNDL"],
            to: localizedResources)
        try Data("resource-only".utf8).write(to: localizedResources.appendingPathComponent("labels.txt"))
        let targets = try BundleInventory.signingTargets(in: app)
        XCTAssertEqual(targets.map(\.lastPathComponent), ["Widget.appex", "Fixture.app"])
        try BundleInventory.ensureExecutablePermissions(in: app)
        for binary in [app.appendingPathComponent("Fixture"), widget.appendingPathComponent("Widget")] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: binary.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        }
        let runner = ProcessRunner()
        for target in targets {
            _ = try await runner.run(
                "/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der", target.path])
        }
        for target in targets { _ = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", target.path]) }
        let execution = try await runner.run(app.appendingPathComponent("Fixture").path, ["executable-permissions-restored"])
        XCTAssertEqual(
            String(decoding: execution.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            "executable-permissions-restored")
        let ipa = directory.appendingPathComponent("fixture.ipa")
        let unpacked = directory.appendingPathComponent("unpacked")
        try Archive.createIPA(from: tree, to: ipa)
        try Archive.extract(ipa, to: unpacked)
        let exportedApp = unpacked.appendingPathComponent("Payload/Fixture.app")
        for target in try BundleInventory.signingTargets(in: exportedApp) {
            _ = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", target.path])
        }
        let exportedWidget = exportedApp.appendingPathComponent("PlugIns/Widget.appex")
        try Data("tampered".utf8).write(to: exportedWidget.appendingPathComponent("sealed.txt"))
        let failed = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", exportedWidget.path], check: false)
        XCTAssertNotEqual(failed.status, 0)
    }

    func testResourceBundleMetadataIsOptionalWhenNoExecutableShips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: app.appendingPathComponent("Fixture"))
        try BundleInventory.writeInfo(["CFBundleIdentifier": "com.example.fixture", "CFBundleExecutable": "Fixture"], to: app)
        let variants: [[String: Any]] = [
            [:], ["CFBundleExecutable": ""], ["CFBundleExecutable": "NotShipped"],
            ["CFBundleIdentifier": "com.example.resources", "CFBundleExecutable": ""]
        ]
        for (index, metadata) in variants.enumerated() {
            let resource = app.appendingPathComponent("Resource\(index).bundle")
            try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: false)
            try BundleInventory.writeInfo(metadata, to: resource)
        }
        XCTAssertEqual(try BundleInventory.discover(in: app).map(\.identifier), ["com.example.fixture"])
        XCTAssertEqual(try BundleInventory.signingTargets(in: app).count, 1)
        let malformedCode = app.appendingPathComponent("Code.bundle")
        try FileManager.default.createDirectory(at: malformedCode, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: malformedCode.appendingPathComponent("Code"))
        try BundleInventory.writeInfo(["CFBundleExecutable": "Code"], to: malformedCode)
        XCTAssertThrowsError(try BundleInventory.discover(in: app)) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "bundle.metadata")
        }
    }

    func testExtensionsArePreservedByDefaultAndRemovedOnlyFromExplicitStagedCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.app")
        let sourceExtension = source.appendingPathComponent("PlugIns/Share.appex")
        let sourceWatch = source.appendingPathComponent("Watch/Companion.app")
        try FileManager.default.createDirectory(at: sourceExtension, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceWatch, withIntermediateDirectories: true)
        try Data("extension data".utf8).write(to: sourceExtension.appendingPathComponent("fixture"))
        let staged = directory.appendingPathComponent("Staged.app")
        try FileManager.default.copyItem(at: source, to: staged)
        XCTAssertTrue(try BundleInventory.removeEmbeddedExtensions(in: staged, enabled: false).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("PlugIns/Share.appex").path))
        let warnings = try BundleInventory.removeEmbeddedExtensions(in: staged, enabled: true)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("Share.appex"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("PlugIns/Share.appex").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Watch/Companion.app").path))
        XCTAssertEqual(try Data(contentsOf: sourceExtension.appendingPathComponent("fixture")), Data("extension data".utf8))
    }
}
