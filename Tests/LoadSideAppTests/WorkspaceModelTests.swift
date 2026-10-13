import Foundation
import LoadSideCore
import XCTest

@testable import LoadSideApp

final class WorkspaceModelTests: XCTestCase {
    @MainActor
    func testNewWorkspaceUsesDefaultPoliciesAndRequiresValidatedInputs() async throws {
        let (model, _) = try await makeWorkspace()

        XCTAssertEqual(model.section, .workspace)
        XCTAssertEqual(model.jobMode, .sign)
        XCTAssertEqual(model.policy, .strict)
        XCTAssertEqual(model.identifierPolicy, .preserve)
        XCTAssertEqual(model.extensionProfilePolicy, .reuseMain)
        XCTAssertFalse(model.removeExtensions)
        XCTAssertFalse(model.showAdvanced)
        XCTAssertFalse(model.profilesReady)
        XCTAssertFalse(model.canSign)
        XCTAssertFalse(model.canSaveSigningProfile)
        XCTAssertEqual(model.missingInputs, "Add an IPA to begin")
        XCTAssertTrue(model.savedSigningProfiles.isEmpty)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(model.localLibrary.apps.isEmpty)
    }

    @MainActor
    func testResetClearsSessionInputsAndRestoresDefaultPolicies() async throws {
        let (model, root) = try await makeWorkspace()
        model.certificate = root.appendingPathComponent("fixture.p12")
        model.password = "public-session-fixture"
        model.injections = [root.appendingPathComponent("fixture.dylib")]
        model.jobMode = .injectOnly
        model.bundleIdentifier = "com.example.override"
        model.identifierPolicy = .automatic
        model.displayName = "Custom name"
        model.policy = .compatible
        model.removeExtensions = true
        model.extensionProfilePolicy = .matching
        model.showAdvanced = true
        model.activeJobID = UUID()

        model.reset()

        XCTAssertNil(model.ipa)
        XCTAssertNil(model.certificate)
        XCTAssertTrue(model.password.isEmpty)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertTrue(model.injections.isEmpty)
        XCTAssertTrue(model.bundleIdentifier.isEmpty)
        XCTAssertTrue(model.displayName.isEmpty)
        XCTAssertEqual(model.jobMode, .sign)
        XCTAssertEqual(model.identifierPolicy, .preserve)
        XCTAssertEqual(model.policy, .strict)
        XCTAssertEqual(model.extensionProfilePolicy, .reuseMain)
        XCTAssertFalse(model.removeExtensions)
        XCTAssertFalse(model.showAdvanced)
        XCTAssertNil(model.activeJobID)
        XCTAssertFalse(model.canSign)
    }

    @MainActor
    func testRunningJobPreventsResetInputReplacementAndPolicyChanges() async throws {
        let (model, root) = try await makeWorkspace()
        let original = root.appendingPathComponent("original.p12")
        let replacement = root.appendingPathComponent("replacement.p12")
        try Data("public-file-fixture".utf8).write(to: replacement)
        model.certificate = original
        model.password = "public-session-fixture"
        model.extensionProfilePolicy = .matching
        let activeID = UUID()
        model.activeJobID = activeID
        model.isRunning = true

        model.reset()
        model.selectExtensionProfilePolicy(.reuseMain, isSelected: true)
        XCTAssertFalse(model.accept([replacement], kind: .certificate))

        XCTAssertEqual(model.certificate, original)
        XCTAssertEqual(model.password, "public-session-fixture")
        XCTAssertEqual(model.extensionProfilePolicy, .matching)
        XCTAssertEqual(model.activeJobID, activeID)
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.canSign)
        XCTAssertFalse(model.canSaveSigningProfile)
        model.isRunning = false
    }

    @MainActor
    func testInputAcceptanceDeduplicatesLibrariesAndRejectsWrongOrMissingFiles() async throws {
        let (model, root) = try await makeWorkspace()
        let library = root.appendingPathComponent("fixture.DYLIB")
        let certificate = root.appendingPathComponent("fixture.P12")
        try Data("public-file-fixture".utf8).write(to: library)
        try Data("public-file-fixture".utf8).write(to: certificate)
        model.section = .guide

        XCTAssertTrue(model.accept([library, library], kind: .injection))
        XCTAssertEqual(model.injections, [library])
        XCTAssertEqual(model.section, .workspace)
        XCTAssertFalse(model.accept([library], kind: .certificate))
        XCTAssertNil(model.certificate)
        XCTAssertFalse(model.accept([root.appendingPathComponent("missing.p12")], kind: .certificate))
        XCTAssertFalse(model.accept([try XCTUnwrap(URL(string: "https://example.invalid/fixture.p12"))]))
        XCTAssertTrue(model.accept([certificate], kind: .certificate))
        XCTAssertEqual(model.certificate, certificate)
        XCTAssertFalse(model.canSign, "File selection alone cannot bypass IPA and provisioning-profile validation")
        XCTAssertFalse(model.canSaveSigningProfile)
    }

    @MainActor
    func testInvalidIPAPreflightBlocksSigningAndUnsignedExportAndClearsOnRemoval() async throws {
        let (model, root) = try await makeWorkspace()
        let ipa = root.appendingPathComponent("invalid.ipa")
        let original = Data("not-an-archive".utf8)
        try original.write(to: ipa)
        model.injections = [root.appendingPathComponent("fixture.dylib")]
        model.jobMode = .injectOnly

        XCTAssertTrue(model.accept([ipa], kind: .ipa))
        XCTAssertTrue(model.isInspectingIPA)
        XCTAssertFalse(model.canSign)
        XCTAssertEqual(model.missingInputs, "Inspecting the application…")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.isInspectingIPA && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isInspectingIPA, "Invalid archive inspection did not finish before its test deadline")
        XCTAssertNotNil(model.ipaInspectionError)
        XCTAssertNil(model.ipaInspection)
        XCTAssertFalse(model.canSign, "Inject-only export also requires a successfully inspected IPA")
        XCTAssertEqual(model.missingInputs, "Resolve the application inspection error")
        model.jobMode = .sign
        XCTAssertFalse(model.canSign)
        XCTAssertEqual(try Data(contentsOf: ipa), original)

        model.ipa = nil
        XCTAssertNil(model.ipaInspectionError)
        XCTAssertNil(model.ipaInspectionRecovery)
        XCTAssertFalse(model.isInspectingIPA)
        XCTAssertEqual(model.missingInputs, "Add an IPA to begin")
    }

    @MainActor
    private func makeWorkspace() async throws -> (WorkspaceModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LoadSide-WorkspaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let model = WorkspaceModel(
            historyStore: JobHistoryStore(url: root.appendingPathComponent("history.json")),
            savedProfileStore: SavedSigningProfileStore(
                directory: root.appendingPathComponent("profiles"), passwords: WorkspaceTestPasswords()),
            localLibrary: LocalLibraryModel(
                store: LocalAppLibrary(directory: root.appendingPathComponent("library")),
                installer: CloudflaredInstaller(directory: root.appendingPathComponent("tools"))))
        addTeardownBlock {
            await model.waitForInitialLoad()
            try FileManager.default.removeItem(at: root)
        }
        await model.waitForInitialLoad()
        return (model, root)
    }
}

private final class WorkspaceTestPasswords: SigningProfilePasswordStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]

    func save(_ password: String, for id: UUID) { lock.withLock { values[id] = password } }
    func load(for id: UUID) -> String? { lock.withLock { values[id] } }
    func delete(for id: UUID) { lock.withLock { values[id] = nil } }
}
