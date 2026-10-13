import Foundation
import XCTest

@testable import LoadSideApp
@testable import LoadSideCore

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
        XCTAssertTrue(model.showAdvanced)
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
    func testSavedSelectionInspectsEachProfileOnceAndRechecksReselection() async throws {
        let probe = ProfileInspectionProbe()
        let (model, root) = try await makeWorkspace(profileInspector: { try await probe.inspect($0) })
        let profiles = [root.appendingPathComponent("main.mobileprovision"), root.appendingPathComponent("extension.mobileprovision")]
        let selection = SavedSigningProfileSelection(
            profile: SavedSigningProfile(
                id: UUID(), name: "Synthetic selection", createdAt: Date(), profileCount: 2,
                remembersPassword: false, expiresAt: Date().addingTimeInterval(60)),
            certificate: root.appendingPathComponent("fixture.p12"), provisioningProfiles: profiles,
            password: nil, passwordNotice: nil)

        model.applySavedSelection(selection)
        await model.waitForProfileInspections()
        let firstCounts = await probe.counts()
        XCTAssertEqual(firstCounts, Dictionary(uniqueKeysWithValues: profiles.map { ($0, 1) }))
        XCTAssertEqual(model.selectedSigningProfileID, selection.profile.id)
        XCTAssertFalse(model.profilesReady, "Synthetic invalid profiles must not bypass validation")

        model.applySavedSelection(selection)
        await model.waitForProfileInspections()
        let secondCounts = await probe.counts()
        XCTAssertEqual(secondCounts, Dictionary(uniqueKeysWithValues: profiles.map { ($0, 2) }))
        XCTAssertFalse(model.profilesReady)
    }

    @MainActor
    func testProfileRetryCancelsOldWorkerAndRejectsItsLateResult() async throws {
        let probe = ProfileInspectionProbe(holdResults: true)
        let (model, root) = try await makeWorkspace(profileInspector: { try await probe.inspect($0) })
        addTeardownBlock { await probe.finishAll() }
        let url = root.appendingPathComponent("fixture.mobileprovision")
        model.profiles = [url]
        // Replace the automatically scheduled check before it starts, retaining a
        // handle so the obsolete worker can be awaited without scheduler assumptions.
        let obsolete = model.inspectProfile(url)
        try await waitForProbe { await probe.requestCount == 1 }

        let replacement = model.inspectProfile(url)
        try await waitForProbe {
            let count = await probe.requestCount
            let cancelled = await probe.wasCancelled(0)
            return count == 2 && cancelled
        }
        await probe.finish(1, message: "Current inspection")
        await replacement.value
        assertInvalidInspection(model, url: url, message: "Current inspection")

        await probe.finish(0, message: "Obsolete inspection")
        await obsolete.value
        assertInvalidInspection(model, url: url, message: "Current inspection")
        XCTAssertFalse(model.profilesReady)
    }

    @MainActor
    func testRemovingProfileCancelsWorkerAndDoesNotRestoreItsResult() async throws {
        let probe = ProfileInspectionProbe(holdResults: true)
        let (model, root) = try await makeWorkspace(profileInspector: { try await probe.inspect($0) })
        addTeardownBlock { await probe.finishAll() }
        let url = root.appendingPathComponent("fixture.mobileprovision")
        model.profiles = [url]
        let removed = model.inspectProfile(url)
        try await waitForProbe { await probe.requestCount == 1 }

        model.profiles = []
        try await waitForProbe { await probe.wasCancelled(0) }
        await probe.finish(0, message: "Removed inspection")
        await removed.value

        XCTAssertTrue(model.profileInspections.isEmpty)
        XCTAssertFalse(model.profilesReady)
        XCTAssertFalse(model.canSign)
    }

    @MainActor
    private func assertInvalidInspection(
        _ model: WorkspaceModel, url: URL, message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .invalid(let actual, _) = model.profileInspections[url] else {
            XCTFail("Expected an invalid profile inspection", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, message, file: file, line: line)
    }

    @MainActor
    private func waitForProbe(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Profile inspection did not reach the expected state before its test deadline")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func makeWorkspace(
        profileInspector: @escaping WorkspaceModel.ProfileInspector = { try ProvisioningProfile.inspect($0) }
    ) async throws -> (WorkspaceModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LoadSide-WorkspaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let preferencesSuite = "LoadSide-WorkspacePreferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: preferencesSuite))
        let model = WorkspaceModel(
            historyStore: JobHistoryStore(url: root.appendingPathComponent("history.json")),
            savedProfileStore: SavedSigningProfileStore(
                directory: root.appendingPathComponent("profiles"), passwords: WorkspaceTestPasswords()),
            localLibrary: LocalLibraryModel(
                store: LocalAppLibrary(directory: root.appendingPathComponent("library")),
                installer: CloudflaredInstaller(directory: root.appendingPathComponent("tools"))),
            disclosurePreferences: DisclosurePreferences(defaults: defaults),
            profileInspector: profileInspector)
        addTeardownBlock {
            UserDefaults(suiteName: preferencesSuite)?.removePersistentDomain(forName: preferencesSuite)
            await model.waitForInitialLoad()
            try FileManager.default.removeItem(at: root)
        }
        await model.waitForInitialLoad()
        return (model, root)
    }
}

private actor ProfileInspectionProbe {
    private var holdResults: Bool
    private var requests: [URL] = []
    private var cancelled: Set<Int> = []
    private var pending: [Int: CheckedContinuation<ProvisioningProfile, any Error>] = [:]

    init(holdResults: Bool = false) { self.holdResults = holdResults }

    var requestCount: Int { requests.count }
    func wasCancelled(_ index: Int) -> Bool { cancelled.contains(index) }
    func counts() -> [URL: Int] { Dictionary(requests.map { ($0, 1) }, uniquingKeysWith: +) }

    func inspect(_ url: URL) async throws -> ProvisioningProfile {
        let index = requests.count
        requests.append(url)
        guard holdResults else { throw LoadSideError("fixture.invalid", "Synthetic invalid profile") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[index] = $0 }
        } onCancel: {
            Task { await self.recordCancellation(index) }
        }
    }

    func finish(_ index: Int, message: String) {
        // Deliberately ignore cancellation until explicitly released, as a synchronous
        // Security operation may still finish after the user changes the selection.
        pending.removeValue(forKey: index)?.resume(throwing: LoadSideError("fixture.invalid", message))
    }

    func finishAll() {
        holdResults = false
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }

    private func recordCancellation(_ index: Int) { cancelled.insert(index) }
}

private final class WorkspaceTestPasswords: SigningProfilePasswordStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]

    func save(_ password: String, for id: UUID) { lock.withLock { values[id] = password } }
    func load(for id: UUID) -> String? { lock.withLock { values[id] } }
    func delete(for id: UUID) { lock.withLock { values[id] = nil } }
}
