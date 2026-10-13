import Foundation
import XCTest
@testable import LoadSideCore

final class InjectionTests: XCTestCase {
    private func app(in root: URL, subtype: UInt32 = 0) throws -> (URL, URL) {
        let app = root.appendingPathComponent("App.app"), binary = app.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try BinaryFixtures.macho(subtype: subtype).write(to: binary)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.example.app", "CFBundleExecutable": "App"], format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        return (app, binary)
    }
    func testInjectStandaloneDylibAndRewriteInstallName() throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (app, binary) = try app(in: root), tweak = root.appendingPathComponent("Tweak.dylib")
        try BinaryFixtures.macho(fileType: 6, dependency: "/usr/lib/libSystem.B.dylib").write(to: tweak)
        let result = try Injection.inject(inputs: [tweak], into: app, executable: binary, workspace: root)
        XCTAssertEqual(result.injectedLibraries.count, 1)
        XCTAssertEqual(try MachO.inspect(binary).slices[0].dependencies, ["@executable_path/Frameworks/Tweak.dylib"])
        XCTAssertEqual(try MachO.inspect(result.injectedLibraries[0]).slices[0].installName, "@executable_path/Frameworks/Tweak.dylib")
    }
    func testUnresolvedSubstrateDependencyRejectedBeforeCopy() throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (app, binary) = try app(in: root), tweak = root.appendingPathComponent("Tweak.dylib")
        try BinaryFixtures.macho(fileType: 6, dependency: "/usr/lib/libsubstrate.dylib").write(to: tweak)
        XCTAssertThrowsError(try Injection.inject(inputs: [tweak], into: app, executable: binary, workspace: root)) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "injection.unresolvedDependency")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/Tweak.dylib").path))
        XCTAssertTrue(try MachO.inspect(binary).slices[0].dependencies.isEmpty)
    }

    func testRootlessAliasConflictsAreRejectedInEitherInputOrderBeforeCopy() throws {
        for reversed in [false, true] {
            let root = try BinaryFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let (app, binary) = try app(in: root)
            let original = try Data(contentsOf: binary)
            let first = root.appendingPathComponent("First.dylib")
            let second = root.appendingPathComponent("Second.dylib")
            for (file, installName) in [(first, "/usr/lib/Shared.dylib"), (second, "/var/jb/usr/lib/Shared.dylib")] {
                try BinaryFixtures.macho(fileType: 6).write(to: file)
                try MachO.rewrite(file, dependencies: [:], installName: installName)
            }
            let inputs = reversed ? [second, first] : [first, second]

            XCTAssertThrowsError(try Injection.inject(inputs: inputs, into: app, executable: binary, workspace: root)) { error in
                XCTAssertEqual((error as? LoadSideError)?.code, "injection.ambiguous")
            }
            XCTAssertEqual(try Data(contentsOf: binary), original)
            for file in inputs {
                XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/" + file.lastPathComponent).path))
            }
        }
    }

    func testUnreadableFrameworkContentsFailBeforeCopyOrCodeChanges() throws {
        let fm = FileManager.default
        let root = try BinaryFixtures.temporaryDirectory()
        let framework = root.appendingPathComponent("Tweak.framework")
        let blocked = framework.appendingPathComponent("Resources")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            try? fm.removeItem(at: root)
        }
        let (app, binary) = try app(in: root)
        let original = try Data(contentsOf: binary)
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        try BinaryFixtures.macho(fileType: 6).write(to: framework.appendingPathComponent("Tweak"))
        try BundleInventory.writeInfo(["CFBundleIdentifier": "test.example.tweak", "CFBundleExecutable": "Tweak"], to: framework)
        try Data("required resource".utf8).write(to: blocked.appendingPathComponent("asset"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        guard (try? fm.contentsOfDirectory(atPath: blocked.path)) == nil else {
            throw XCTSkip("This user can read directories despite restrictive permissions.")
        }

        XCTAssertThrowsError(try Injection.inject(inputs: [framework], into: app, executable: binary, workspace: root))
        XCTAssertEqual(try Data(contentsOf: binary), original)
        XCTAssertFalse(fm.fileExists(atPath: app.appendingPathComponent("Frameworks/Tweak.framework").path))
    }
    func testDEBExtractsTweakAndDependencyWithoutInstallingScripts() throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (app, binary) = try app(in: root), deb = root.appendingPathComponent("Tweak.deb")
        var dependency = Array(BinaryFixtures.macho(fileType: 6))
        // Give the dependency a distinct install name to avoid ambiguous linkage.
        let dependencyFile = root.appendingPathComponent("Dependency.dylib")
        try Data(dependency).write(to: dependencyFile)
        try MachO.rewrite(dependencyFile, dependencies: [:], installName: "/usr/lib/Dependency.dylib")
        dependency = Array(try Data(contentsOf: dependencyFile))
        let filter = try PropertyListSerialization.data(fromPropertyList: ["Filter": ["Bundles": ["test.example.app"]]], format: .xml, options: 0)
        let payload = ArchiveFixtures.tar([
            .init(path: "Library/MobileSubstrate/DynamicLibraries/Tweak.dylib", data: BinaryFixtures.macho(fileType: 6, dependency: "/usr/lib/Dependency.dylib")),
            .init(path: "Library/MobileSubstrate/DynamicLibraries/Tweak.plist", data: filter),
            .init(path: "usr/lib/Dependency.dylib", data: Data(dependency)),
            .init(path: "usr/bin/never-run", data: Data("#!/bin/sh\ntouch /tmp/loadside-script-must-not-run".utf8))
        ])
        try ArchiveFixtures.deb(data: payload).write(to: deb)
        let result = try Injection.inject(inputs: [deb], into: app, executable: binary, workspace: root)
        XCTAssertEqual(result.injectedLibraries.count, 2)
        XCTAssertEqual(try MachO.inspect(binary).slices[0].dependencies, ["@executable_path/Frameworks/Tweak.dylib"])
        XCTAssertEqual(try MachO.inspect(app.appendingPathComponent("Frameworks/Tweak.dylib")).slices[0].dependencies, ["@executable_path/Frameworks/Dependency.dylib"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("usr/bin/never-run").path))
        XCTAssertFalse(result.warnings.isEmpty)
    }
    func testWrongSubstrateFilterAndLibraryOnlyDEBAreRejected() throws {
        let filter = try PropertyListSerialization.data(fromPropertyList: ["Filter": ["Bundles": ["another.app"]]], format: .xml, options: 0)
        for entries in [
            [ArchiveFixtures.Entry(path: "Library/MobileSubstrate/DynamicLibraries/Tweak.dylib", data: BinaryFixtures.macho(fileType: 6)), .init(path: "Library/MobileSubstrate/DynamicLibraries/Tweak.plist", data: filter)],
            [.init(path: "usr/lib/Library.dylib", data: BinaryFixtures.macho(fileType: 6))]
        ] {
            let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let (app, binary) = try app(in: root), deb = root.appendingPathComponent("Tweak.deb")
            try ArchiveFixtures.deb(data: ArchiveFixtures.tar(entries)).write(to: deb)
            XCTAssertThrowsError(try Injection.inject(inputs: [deb], into: app, executable: binary, workspace: root))
        }
    }
    func testDEBRetainsNestedApplicationSupportResourcesAtAppRoot() throws {
        for prefix in ["", "var/jb/"] {
            let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let (app, binary) = try app(in: root), deb = root.appendingPathComponent("Resources.deb")
            let icon = Data("resource image fixture".utf8)
            try ArchiveFixtures.deb(data: ArchiveFixtures.tar([
                .init(path: prefix + "Library/MobileSubstrate/DynamicLibraries/Tweak.dylib", data: BinaryFixtures.macho(fileType: 6)),
                .init(path: prefix + "Library/Application Support/Package/Assets.bundle/icon.png", data: icon)
            ])).write(to: deb)
            let result = try Injection.inject(inputs: [deb], into: app, executable: binary, workspace: root)
            XCTAssertEqual(result.injectedLibraries.count, 1)
            XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Assets.bundle/icon.png")), icon)
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/Assets.bundle").path))
            XCTAssertTrue(result.warnings.contains { $0.contains("Embedded resource bundle Assets.bundle") })
        }
    }
    func testResourceBundleCollisionAndHiddenCodeFailBeforeInjection() throws {
        for hiddenCode in [false, true] {
            let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let (app, binary) = try app(in: root), deb = root.appendingPathComponent("Resources.deb")
            let original = try Data(contentsOf: binary)
            if !hiddenCode {
                try FileManager.default.createDirectory(at: app.appendingPathComponent("Assets.bundle"), withIntermediateDirectories: false)
            }
            try ArchiveFixtures.deb(data: ArchiveFixtures.tar([
                .init(path: "Library/MobileSubstrate/DynamicLibraries/Tweak.dylib", data: BinaryFixtures.macho(fileType: 6)),
                .init(path: "Library/Application Support/Package/Assets.bundle/resource", data: hiddenCode ? BinaryFixtures.macho(fileType: 6) : Data("asset".utf8))
            ])).write(to: deb)
            XCTAssertThrowsError(try Injection.inject(inputs: [deb], into: app, executable: binary, workspace: root)) { error in
                XCTAssertEqual((error as? LoadSideError)?.code, hiddenCode ? "injection.nestedCode" : "injection.collision")
            }
            XCTAssertEqual(try Data(contentsOf: binary), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Frameworks/Tweak.dylib").path))
        }
    }
    func testDuplicateNestedResourceBundleNamesAreRejected() throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (app, binary) = try app(in: root), deb = root.appendingPathComponent("Resources.deb")
        try ArchiveFixtures.deb(data: ArchiveFixtures.tar([
            .init(path: "Library/MobileSubstrate/DynamicLibraries/Tweak.dylib", data: BinaryFixtures.macho(fileType: 6)),
            .init(path: "Library/Application Support/First/Assets.bundle/a", data: Data("first".utf8)),
            .init(path: "Library/Application Support/Second/Assets.bundle/a", data: Data("second".utf8))
        ])).write(to: deb)
        XCTAssertThrowsError(try Injection.inject(inputs: [deb], into: app, executable: binary, workspace: root)) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "injection.collision")
        }
        XCTAssertTrue(try MachO.inspect(binary).slices[0].dependencies.isEmpty)
    }
    func testArm64eOnlyLibraryCannotLoadIntoArm64Application() throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (app, binary) = try app(in: root), tweak = root.appendingPathComponent("Tweak.dylib")
        try BinaryFixtures.macho(fileType: 6, subtype: 2).write(to: tweak)
        XCTAssertThrowsError(try Injection.inject(inputs: [tweak], into: app, executable: binary, workspace: root)) { error in
            XCTAssertEqual((error as? LoadSideError)?.code, "injection.architecture")
        }
    }
}

extension InjectionTests {
    /// Exercises the parser/editor against Apple's linker output, then validates the resulting CodeDirectories.
    /// This is local cryptographic verification; a valid Apple profile is still required to install on a device.
    func testRealIOSLinkerOutputInjectionAndAdHocSigning() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessRunner()
        let selected = try await runner.run("/usr/bin/xcode-select", ["-p"])
        let developer = String(decoding: selected.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let sdk = URL(fileURLWithPath: developer).appendingPathComponent("Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")
        let clang = URL(fileURLWithPath: developer).appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
        guard FileManager.default.fileExists(atPath: sdk.path), FileManager.default.isExecutableFile(atPath: clang.path) else { throw XCTSkip("The full Xcode iOS SDK is required for the real Mach-O integration fixture.") }
        let app = root.appendingPathComponent("Real.app"), binary = app.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let mainSource = root.appendingPathComponent("main.c"), librarySource = root.appendingPathComponent("tweak.c"), library = root.appendingPathComponent("RealTweak.dylib")
        try Data("int main(void) { return 0; }\n".utf8).write(to: mainSource)
        try Data("int loadside_fixture(void) { return 42; }\n".utf8).write(to: librarySource)
        let flags = ["-target", "arm64-apple-ios14.0", "-isysroot", sdk.path, "-nostdlib", "-lSystem", "-fno-stack-protector", "-Wl,-headerpad,0x1000"]
        _ = try await runner.run("/usr/bin/env", ["TMPDIR=" + root.path, clang.path] + flags + ["-Wl,-e,_main", mainSource.path, "-o", binary.path])
        _ = try await runner.run("/usr/bin/env", ["TMPDIR=" + root.path, clang.path] + flags + ["-dynamiclib", "-Wl,-install_name,@rpath/RealTweak.dylib", librarySource.path, "-o", library.path])
        let info: [String: Any] = ["CFBundleIdentifier": "test.loadside.real", "CFBundleExecutable": "Real", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertEqual(try MachO.inspect(binary).architectures, ["arm64"])
        XCTAssertEqual(try MachO.inspect(library).slices[0].platform, 2)
        let result = try Injection.inject(inputs: [library], into: app, executable: binary, workspace: root)
        XCTAssertEqual(result.injectedLibraries.count, 1)
        XCTAssertTrue(try MachO.inspect(binary).slices[0].dependencies.contains("@executable_path/Frameworks/RealTweak.dylib"))
        _ = try await runner.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", result.injectedLibraries[0].path])
        _ = try await runner.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", app.path])
        _ = try await runner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let ipa = root.appendingPathComponent("Real.ipa"), payload = root.appendingPathComponent("export/Payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: payload.appendingPathComponent("Real.app"))
        try Archive.createIPA(from: payload.deletingLastPathComponent(), to: ipa)
        let unpacked = root.appendingPathComponent("verified")
        try Archive.extract(ipa, to: unpacked)
        _ = try await runner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", unpacked.appendingPathComponent("Payload/Real.app").path])
    }
}
