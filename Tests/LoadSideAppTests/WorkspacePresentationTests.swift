import AppKit
import CryptoKit
import LoadSideCore
import SwiftUI
import XCTest

@testable import LoadSideApp

/// Test-local overrides never change the user's appearance or accessibility settings.
struct UIHostConfiguration {
    var name = "desktop-light"
    var size = AppMetrics.defaultWindowSize
    var colorScheme: ColorScheme = .light
    var increasedContrast = false
    var nativeWindow = false

    var appearance: NSAppearance.Name {
        if increasedContrast { return colorScheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua }
        return colorScheme == .dark ? .darkAqua : .aqua
    }

    static let standard = Self()
    static let minimumLight = Self(name: "minimum-light", size: AppMetrics.minimumWindowSize)
    static let desktopDark = Self(name: "desktop-dark", colorScheme: .dark)
    static let accessibleDark = Self(
        name: "minimum-high-contrast-dark", size: AppMetrics.minimumWindowSize, colorScheme: .dark, increasedContrast: true)
    static let nativeMinimum = Self(name: "native-minimum-light", size: AppMetrics.minimumWindowSize, nativeWindow: true)
}

final class WorkspacePresentationTests: XCTestCase {
    @MainActor
    func testNativeMinimumWindowKeepsNavigationAndDestinationsInsideItsContentArea() async throws {
        let fixture = try await WorkspaceUIFixture(unreadableProfile: true)
        defer { fixture.close() }
        // Match the app's minimum frame and normal NSHostingView intrinsic sizing.
        // This catches destination changes that grow or displace the native split.
        let host = AccessibilityHost(
            MainView(model: fixture.model)
                .frame(minWidth: AppMetrics.minimumWindowSize.width, minHeight: AppMetrics.minimumWindowSize.height),
            configuration: .nativeMinimum)
        defer { host.close() }
        try await host.wait("Install the native workspace and toolbar") { host.find(identifier: "export") != nil }
        // Initial toolbar installation can increase an NSHostingView window's
        // height. Apply the exact test viewport after that native setup finishes.
        try await host.resize(to: AppMetrics.minimumWindowSize)
        let destinations: [(AppSection, String?)] = [
            (.workspace, nil), (.signingProfiles, "Signing Profiles"), (.library, "Local Library"),
            (.activity, "Activity"), (.guide, nil), (.workspace, nil), (.signingProfiles, "Signing Profiles")
        ]
        for (section, heading) in destinations {
            fixture.model.section = section  // Same navigation path as the app menu.
            try await host.wait("Render native \(section.rawValue)") {
                host.find(identifier: "navigation.\(section)")?.hasSelectedTrait == true
                    && (heading.map { host.contains(text: $0) } ?? true)
            }
            for destination in AppSection.allCases {
                host.assertVisible(try await host.element(identifier: "navigation.\(destination)"))
            }
            if let heading {
                host.assertVisible(try await host.element(label: heading, role: NSAccessibility.Role(rawValue: "AXHeading")))
            }
            if section == .workspace { host.assertVisible(try await host.element(identifier: "export")) }
            try await host.snapshot("fixture-native-\(section)-minimum-light")
        }
        for size in [AppMetrics.defaultWindowSize, AppMetrics.minimumWindowSize] {
            try await host.resize(to: size)
            for destination in AppSection.allCases {
                host.assertVisible(try await host.element(identifier: "navigation.\(destination)"))
            }
            host.assertVisible(try await host.element(label: "Signing Profiles", role: NSAccessibility.Role(rawValue: "AXHeading")))
        }
    }

    @MainActor
    func testExportAndNavigationRemainVisibleAcrossWindowAndAppearanceConfigurations() async throws {
        let fixture = try await WorkspaceUIFixture()
        defer { fixture.close() }
        for configuration in [UIHostConfiguration.minimumLight, .desktopDark, .accessibleDark] {
            fixture.model.section = .workspace
            let host = AccessibilityHost(MainView(model: fixture.model), configuration: configuration)
            defer { host.close() }

            for mode in [JobMode.sign, .injectOnly] {
                fixture.model.jobMode = mode
                let label = mode == .sign ? "Sign & Export…" : "Inject & Export…"
                try await host.wait("Render the \(mode) export action") { host.find(identifier: "export")?.label == label }
                let export = try await host.element(identifier: "export")
                XCTAssertFalse(export.isEnabled)
                host.assertVisible(export)
                for section in AppSection.allCases {
                    host.assertVisible(try await host.element(identifier: "navigation.\(section)"))
                }
                try await host.snapshot("empty-workspace-\(mode)-\(configuration.name)")
            }

            for section in [AppSection.signingProfiles, .library, .activity, .guide] {
                try await host.press(identifier: "navigation.\(section)")
                try await host.wait("Show \(section.rawValue)") { fixture.model.section == section }
                host.assertVisible(try await host.element(identifier: "navigation.\(section)"))
                try await host.snapshot("empty-\(section)-\(configuration.name)")
            }
            XCTAssertFalse(fixture.model.localLibrary.needsShutdown)
        }
    }

    @MainActor
    func testLibraryEmptyActionRestoresSigningAndCancellationCannotBeRepeated() async throws {
        let fixture = try await WorkspaceUIFixture()
        defer {
            fixture.model.isRunning = false
            fixture.model.isCancelling = false
            fixture.close()
        }
        fixture.model.jobMode = .injectOnly
        fixture.model.section = .library
        let host = AccessibilityHost(MainView(model: fixture.model), configuration: .minimumLight)
        defer { host.close() }
        let emptyHost = AccessibilityHost(LibraryEmptyState(model: fixture.model), configuration: .minimumLight)
        defer { emptyHost.close() }
        try await emptyHost.press(label: "Open Workspace", role: .button)
        try await host.wait("Return to signing from the empty library") {
            fixture.model.section == .workspace && fixture.model.jobMode == .sign
                && host.find(identifier: "export")?.label == "Sign & Export…"
        }

        fixture.model.isRunning = true
        fixture.model.isCancelling = true
        let cancel = try await host.element(identifier: "workspace.cancel")
        XCTAssertEqual(cancel.label, "Cancelling…")
        XCTAssertFalse(cancel.isEnabled)
        host.assertVisible(cancel)
        XCTAssertNil(host.find(identifier: "export"))
        XCTAssertTrue(host.contains(text: "Keep LoadSide open until cleanup finishes."))
        let disabledOpen = try await emptyHost.element(label: "Open Workspace", role: .button)
        XCTAssertFalse(disabledOpen.isEnabled)
        try await host.snapshot("fixture-workspace-cancelling-minimum-light")
    }

    @MainActor
    func testTerminalActivityPreservesLongDiagnosticsWithoutClaimingWorkIsRunning() async throws {
        let fixture = try await WorkspaceUIFixture()
        defer { fixture.close() }
        let message =
            "UI fixture: The provisioning profile does not authorize com.example.application.with.a.long.bundle.identifier. "
            + "The original archive is unchanged, and no final IPA was exported."
        let recovery = "Choose a matching provisioning profile, then return to Workspace and export again."
        let records = [JobStatus.failed, .cancelled, .completed].map { status in
            presentationRecord(
                status: status, directory: fixture.directory, failure: status == .completed ? nil : message,
                recovery: status == .completed ? nil : recovery)
        }
        fixture.model.history = records
        fixture.model.section = .activity
        let host = AccessibilityHost(MainView(model: fixture.model), configuration: .desktopDark)
        defer { host.close() }
        for record in records {
            fixture.model.selectedJobID = record.id
            let detail = AccessibilityHost(JobDetailView(model: fixture.model, job: record).padding(24), configuration: .desktopDark)
            defer { detail.close() }
            try await detail.wait("Show the terminal record and its empty log") { detail.contains(text: "No events were recorded.") }
            XCTAssertFalse(detail.contains(text: "Waiting for the export engine…"))
            XCTAssertFalse(fixture.model.isRunning)
            if record.failure != nil {
                try await host.wait("Expose the full diagnostic and recovery") {
                    host.contains(text: message) && host.contains(text: recovery)
                }
            }
            try await host.snapshot("fixture-activity-\(record.status)-desktop-dark")
        }
    }

    @MainActor
    func testPopulatedFixturesRetainReadinessAndPrivateLibraryBoundaries() async throws {
        let fixture = try await WorkspaceUIFixture(unreadableProfile: true)
        defer { fixture.close() }
        let ipa = try makePresentationIPA(in: fixture.directory)
        XCTAssertTrue(fixture.model.accept([ipa], kind: .ipa))
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.model.isInspectingIPA && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.model.ipaInspection?.bundleIdentifier, "com.example.presentation")
        XCTAssertNil(fixture.model.ipaInspectionError)
        let injection = fixture.directory.appendingPathComponent("UI-Fixture-Library-With-A-Long-Descriptive-Filename.dylib")
        try Data("UI layout fixture only; never executed or injected".utf8).write(to: injection)
        XCTAssertTrue(fixture.model.accept([injection], kind: .injection))
        let source = try Data(contentsOf: ipa)

        for configuration in [UIHostConfiguration.minimumLight, .desktopDark, .accessibleDark] {
            fixture.model.section = .workspace
            let host = AccessibilityHost(MainView(model: fixture.model), configuration: configuration)
            defer { host.close() }
            for mode in [JobMode.sign, .injectOnly] {
                fixture.model.jobMode = mode
                try await host.wait("Render populated workflow readiness") {
                    host.find(identifier: "export")?.isEnabled == (mode == .injectOnly)
                }
                host.assertVisible(try await host.element(identifier: "export"))
                XCTAssertEqual(fixture.model.canSign, mode == .injectOnly)
                try await host.snapshot("fixture-workspace-populated-\(mode)-\(configuration.name)")
            }
            fixture.model.section = .signingProfiles
            let issue = try XCTUnwrap(fixture.model.savedSigningProfiles.first?.issue)
            try await host.wait("Expose the unreadable profile's full diagnostic") { host.contains(text: issue) }
            XCTAssertEqual(fixture.model.savedSigningProfiles.count, 1)
            XCTAssertNotNil(fixture.model.savedSigningProfiles.first?.issue)
            let unavailableDate = Date.distantPast.formatted(date: .abbreviated, time: .omitted)
            XCTAssertFalse(host.contains(text: "Saved \(unavailableDate)"))
            XCTAssertFalse(host.contains(text: "Earliest expiry \(unavailableDate)"))
            try await host.snapshot("fixture-profiles-unavailable-\(configuration.name)")
        }

        // Synthetic metadata is confined to this temporary test store. It is not
        // a successful engine export, a trusted signature, or an installable app.
        let result = SigningResult(
            output: ipa, bundleIdentifier: "com.example.presentation", displayName: "UI Fixture — Library Presentation",
            certificateName: "Synthetic UI fixture", teamIdentifier: "UIFIXTURE", signedCodeCount: 1,
            injectedLibraryCount: 0, warnings: [], sha256: SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(),
            bundleVersion: "1")
        await fixture.model.localLibrary.add(result)
        XCTAssertEqual(fixture.model.localLibrary.apps.count, 1)
        XCTAssertFalse(fixture.model.localLibrary.needsShutdown)
        fixture.model.section = .library
        let libraryHost = AccessibilityHost(MainView(model: fixture.model), configuration: .desktopDark)
        defer { libraryHost.close() }
        try await libraryHost.wait("Show the private fixture library") { libraryHost.contains(text: "Local Library") }
        try await libraryHost.snapshot("fixture-library-populated-desktop-dark")
        XCTAssertEqual(try Data(contentsOf: ipa), source)
        fixture.model.ipa = nil
    }
}

private func presentationRecord(status: JobStatus, directory: URL, failure: String?, recovery: String?) -> JobRecord {
    JobRecord(
        id: UUID(), startedAt: Date(timeIntervalSince1970: 1_800_000_000), finishedAt: Date(timeIntervalSince1970: 1_800_000_012),
        sourceName: "UI-Fixture-Application-With-An-Intentionally-Long-Archive-Filename-For-Layout-Review.ipa", status: status,
        output: directory.appendingPathComponent("Never-exported.ipa"), events: [], failure: failure, recovery: recovery,
        entitlementPolicy: .strict, profileCount: 1, injectionNames: [], removeExtensions: false,
        bundleIdentifierPolicy: .preserve, extensionProfilePolicy: .reuseMain, jobMode: .sign)
}

/// A structural archive for real preflight, not runnable code. The test does not
/// sign, execute, inject into, or distribute this synthetic application.
private func makePresentationIPA(in directory: URL) throws -> URL {
    let tree = directory.appendingPathComponent("archive")
    let app = tree.appendingPathComponent("Payload/Presentation.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let info = [
        "CFBundleIdentifier": "com.example.presentation", "CFBundleExecutable": "Presentation",
        "CFBundleDisplayName": "UI Fixture — Application Presentation", "CFBundleVersion": "1"
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
    let header: [UInt32] = [0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 0, 0]
    let bytes = header.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    try Data(bytes).write(to: app.appendingPathComponent("Presentation"))
    let ipa = directory.appendingPathComponent("UI-Fixture-Application-With-A-Long-Descriptive-Archive-Filename.ipa")
    try Archive.createIPA(from: tree, to: ipa)
    return ipa
}
