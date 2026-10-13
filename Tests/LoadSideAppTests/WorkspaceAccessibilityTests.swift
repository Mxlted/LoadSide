import AppKit
import LoadSideCore
import SwiftUI
import XCTest

@testable import LoadSideApp

final class WorkspaceAccessibilityTests: XCTestCase {
    @MainActor
    func testSidebarNavigationUpdatesSelectionAndVisibleSections() async throws {
        let fixture = try await WorkspaceUIFixture()
        defer { fixture.close() }
        let host = AccessibilityHost(MainView(model: fixture.model))
        defer { host.close() }

        let destinations: [(AppSection, String?)] = [
            (.guide, nil), (.activity, "No export activity"),
            (.signingProfiles, "No saved signing profiles"),
            (.library, "Your next export appears here"), (.workspace, "Prepare an app")
        ]
        for (section, heading) in destinations {
            try await host.press(identifier: "navigation.\(section)")
            try await host.wait("Navigate to \(section.rawValue)") {
                fixture.model.section == section && (heading.map { host.contains(text: $0) } ?? true)
                    && host.find(identifier: "navigation.\(section)")?.hasSelectedTrait == true
            }
        }
        XCTAssertTrue(fixture.model.history.isEmpty)
        XCTAssertTrue(fixture.model.savedSigningProfiles.isEmpty)
        XCTAssertTrue(fixture.model.localLibrary.apps.isEmpty)
        XCTAssertFalse(fixture.model.localLibrary.needsShutdown)
    }

    @MainActor
    func testOpeningWorkspaceFromProfilesRestoresSigningWithExportDisabled() async throws {
        let fixture = try await WorkspaceUIFixture()
        defer { fixture.close() }
        fixture.model.jobMode = .injectOnly
        let host = AccessibilityHost(MainView(model: fixture.model))
        defer { host.close() }

        let unsignedExport = try await host.element(identifier: "export")
        XCTAssertEqual(unsignedExport.label, "Inject & Export…")
        XCTAssertFalse(unsignedExport.isEnabled)
        XCTAssertTrue(host.contains(text: "Unsigned output · Sign before installation"))
        try await host.press(identifier: "navigation.signingProfiles")
        try await host.press(label: "Open Workspace", role: .button)
        try await host.wait("Return to the signing workspace") {
            fixture.model.section == .workspace && fixture.model.jobMode == .sign
                && host.find(identifier: "export")?.label == "Sign & Export…"
        }
        let signingExport = try await host.element(identifier: "export")
        XCTAssertFalse(signingExport.isEnabled)
        XCTAssertEqual(fixture.model.missingInputs, "Add an IPA to begin")
        XCTAssertNil(fixture.model.notice)
    }

    @MainActor
    func testExtensionPolicyCheckboxesRemainMutuallyExclusive() async throws {
        let fixture = try await WorkspaceUIFixture()
        defer { fixture.close() }
        let host = AccessibilityHost(SigningOptionsHarness(model: fixture.model))
        defer { host.close() }

        try await host.press(labelPrefix: "Extensions", role: .disclosureTriangle)
        try await assertPolicy(.reuseMain, model: fixture.model, host: host)
        try await host.press(identifier: "extension-policy.reuse-main")
        try await assertPolicy(.reuseMain, model: fixture.model, host: host)
        try await host.press(identifier: "extension-policy.matching")
        try await assertPolicy(.matching, model: fixture.model, host: host)
        try await host.press(identifier: "extension-policy.matching")
        try await assertPolicy(.matching, model: fixture.model, host: host)
        try await host.press(identifier: "extension-policy.reuse-main")
        try await assertPolicy(.reuseMain, model: fixture.model, host: host)
    }

    @MainActor
    func testDisclosureHeadersAndNestedControlsHaveIndependentActions() async throws {
        let fixture = try await WorkspaceUIFixture()
        defer { fixture.close() }
        let host = AccessibilityHost(SigningOptionsHarness(model: fixture.model))
        defer { host.close() }

        let extensions = try await host.element(labelPrefix: "Extensions", role: .disclosureTriangle)
        XCTAssertFalse(extensions.isSelected)
        XCTAssertNil(host.find(identifier: "extension-policy.reuse-main"))
        try await host.press(labelPrefix: "Extensions", role: .disclosureTriangle)
        try await host.wait("Expand the extension header") {
            host.find(labelPrefix: "Extensions", role: .disclosureTriangle)?.isSelected == true
        }
        try await host.press(label: "Experimental compatibility", role: .disclosureTriangle)
        try await host.wait("Expand the nested compatibility header") {
            host.find(label: "Experimental compatibility", role: .disclosureTriangle)?.isSelected == true
        }
        XCTAssertEqual(host.find(labelPrefix: "Extensions", role: .disclosureTriangle)?.isSelected, true)
        try await host.press(label: "Experimental compatibility", role: .disclosureTriangle)
        try await host.wait("Collapse only the nested header") {
            host.find(label: "Experimental compatibility", role: .disclosureTriangle)?.isSelected == false
        }
        XCTAssertEqual(host.find(labelPrefix: "Extensions", role: .disclosureTriangle)?.isSelected, true)
        try await host.press(labelPrefix: "Extensions", role: .disclosureTriangle)
        try await host.wait("Collapse the extension header") {
            host.find(labelPrefix: "Extensions", role: .disclosureTriangle)?.isSelected == false
                && host.find(identifier: "extension-policy.reuse-main") == nil
        }

        try await host.press(label: "App overrides", role: .disclosureTriangle)
        try await host.wait("Expose app override controls") { fixture.model.showAdvanced }
        try await host.press(label: "App overrides", role: .disclosureTriangle)
        try await host.wait("Hide app override controls") { !fixture.model.showAdvanced }
    }

    @MainActor
    func testRunningExportDisablesWorkflowAndSigningOptions() async throws {
        let fixture = try await WorkspaceUIFixture()
        defer {
            fixture.model.isRunning = false
            fixture.close()
        }
        let workspace = AccessibilityHost(MainView(model: fixture.model))
        defer { workspace.close() }
        let options = AccessibilityHost(SigningOptionsHarness(model: fixture.model))
        defer { options.close() }
        try await options.press(labelPrefix: "Extensions", role: .disclosureTriangle)
        try await options.press(labelPrefix: "Entitlements", role: .disclosureTriangle)
        _ = try await options.element(identifier: "extension-policy.matching")
        fixture.model.isRunning = true

        try await workspace.wait("Disable workflow changes during export") {
            workspace.find(label: "Inject only", role: .radioButton)?.isEnabled == false
                && workspace.find(identifier: "export") == nil
        }
        try await options.wait("Disable signing policy changes during export") {
            options.find(identifier: "extension-policy.matching")?.isEnabled == false
                && options.find(identifier: "extension-policy.reuse-main")?.isEnabled == false
                && options.find(label: "Automatic", role: .radioButton)?.isEnabled == false
                && options.find(label: "Compatible", role: .radioButton)?.isEnabled == false
        }
        fixture.model.isRunning = false
        try await options.wait("Restore editable signing options") {
            options.find(identifier: "extension-policy.matching")?.isEnabled == true
        }
        let export = try await workspace.element(identifier: "export")
        XCTAssertFalse(export.isEnabled)
    }

    @MainActor
    private func assertPolicy(_ policy: ExtensionProfilePolicy, model: WorkspaceModel, host: AccessibilityHost) async throws {
        try await host.wait("Select exactly one extension policy") {
            model.extensionProfilePolicy == policy
                && host.find(identifier: "extension-policy.reuse-main")?.isSelected == (policy == .reuseMain)
                && host.find(identifier: "extension-policy.matching")?.isSelected == (policy == .matching)
        }
    }
}

/// The in-process SwiftUI accessibility bridge omits virtual controls inside
/// scroll views. Host the same production component directly for option tests;
/// its state remains installed in a View, and no control implementation is copied.
private struct SigningOptionsHarness: View {
    @ObservedObject var model: WorkspaceModel
    @State private var extensionList = false
    @State private var compatibility = false
    @State private var extensions = false
    @State private var entitlements = false

    var body: some View {
        SigningOptionsView(
            model: model, showExtensionList: $extensionList, showCompatibilityDetails: $compatibility,
            showExtensionOptions: $extensions, showEntitlements: $entitlements
        )
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .padding(24)
    }
}

/// Only private temporary stores enter the app. Remembered passwords remain in
/// memory; the fixture never reads user history, profiles, or the macOS Keychain.
@MainActor
private final class WorkspaceUIFixture {
    let directory: URL
    let model: WorkspaceModel

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LoadSide-UI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        model = WorkspaceModel(
            historyStore: JobHistoryStore(url: directory.appendingPathComponent("history.json")),
            savedProfileStore: SavedSigningProfileStore(
                directory: directory.appendingPathComponent("profiles"), passwords: MemoryPasswords()),
            localLibrary: LocalLibraryModel(
                store: LocalAppLibrary(directory: directory.appendingPathComponent("library")),
                installer: CloudflaredInstaller(directory: directory.appendingPathComponent("tools"))))
        await model.waitForInitialLoad()
    }

    func close() {
        XCTAssertFalse(model.localLibrary.needsShutdown)
        XCTAssertFalse(model.isRunning)
        XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
    }
}

/// All mutable state is protected by the lock, including reads.
private final class MemoryPasswords: SigningProfilePasswordStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [UUID: String] = [:]

    func save(_ password: String, for id: UUID) { lock.withLock { passwords[id] = password } }
    func load(for id: UUID) -> String? { lock.withLock { passwords[id] } }
    func delete(for id: UUID) { lock.withLock { passwords[id] = nil } }
}

/// Uses only public AppKit accessibility methods, within the test process. A
/// graphical macOS session is required; Accessibility permission is not required.
@MainActor
private final class AccessibilityHost {
    private static let application: NSApplication = {
        let application = NSApplication.shared
        application.finishLaunching()
        return application
    }()
    private let window: NSWindow
    private let view: NSHostingView<AnyView>

    init<Content: View>(_ content: Content) {
        _ = Self.application
        // Explicitly enable the documented SwiftUI accessibility environment so
        // tests don't depend on whether the user runs an assistive technology.
        view = NSHostingView(rootView: AnyView(content.environment(\.accessibilityEnabled, true)))
        window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1408, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    func wait(_ expectation: String, condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            view.layoutSubtreeIfNeeded()
            pumpRunLoop()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        _ = try XCTUnwrap(condition() ? true : nil, "Timed out: \(expectation)\n\(description)", file: file, line: line)
    }

    func element(
        identifier: String? = nil, label: String? = nil, labelPrefix: String? = nil, role: NSAccessibility.Role? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> AccessibilityElement {
        let explanation = identifier ?? label ?? labelPrefix ?? role?.rawValue ?? "accessibility element"
        try await wait(
            "Find \(explanation)",
            condition: {
                self.find(identifier: identifier, label: label, labelPrefix: labelPrefix, role: role) != nil
            }, file: file, line: line)
        return try XCTUnwrap(find(identifier: identifier, label: label, labelPrefix: labelPrefix, role: role), file: file, line: line)
    }

    func press(
        identifier: String? = nil, label: String? = nil, labelPrefix: String? = nil, role: NSAccessibility.Role? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let control = try await element(identifier: identifier, label: label, labelPrefix: labelPrefix, role: role, file: file, line: line)
        XCTAssertTrue(control.isEnabled, "The requested control is disabled", file: file, line: line)
        let accepted = await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume(returning: control.press()) }
        }
        XCTAssertTrue(accepted, "The control did not accept its accessibility press action", file: file, line: line)
    }

    func find(identifier: String? = nil, label: String? = nil, labelPrefix: String? = nil, role: NSAccessibility.Role? = nil)
        -> AccessibilityElement?
    {
        elements.first { element in
            (identifier == nil || element.identifier == identifier)
                && (label == nil || element.label == label)
                && (labelPrefix.map { element.label?.hasPrefix($0) == true } ?? true)
                && (role == nil || element.role == role)
        }
    }

    func contains(text: String) -> Bool { elements.contains { $0.label == text || $0.value as? String == text } }

    private func pumpRunLoop() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    private var description: String {
        elements.map {
            "\($0.role?.rawValue ?? "?") id=\($0.identifier ?? "") label=\($0.label ?? "") value=\(String(describing: $0.value))"
        }
        .joined(separator: "\n")
    }

    private var elements: [AccessibilityElement] {
        var result: [AccessibilityElement] = []
        var pending: [Any] = [view]
        var visited = Set<ObjectIdentifier>()
        while let candidate = pending.popLast() {
            let element = AccessibilityElement(object: candidate as AnyObject)
            guard visited.insert(ObjectIdentifier(element.object)).inserted else { continue }
            result.append(element)
            pending.append(contentsOf: element.children)
        }
        return result
    }

}

/// SwiftUI virtual nodes implement the documented Objective-C accessibility
/// methods without conforming to the complete NSAccessibilityProtocol.
@MainActor
private struct AccessibilityElement {
    let object: AnyObject
    var identifier: String? { object.accessibilityIdentifier?() ?? nil }
    var label: String? { object.accessibilityLabel?() ?? nil }
    var role: NSAccessibility.Role? { object.accessibilityRole?() ?? nil }
    var value: Any? { object.accessibilityValue?() ?? nil }
    var isEnabled: Bool { object.isAccessibilityEnabled?() ?? false }
    var isSelected: Bool { (value as? NSNumber)?.boolValue == true }
    var hasSelectedTrait: Bool { object.isAccessibilitySelected?() ?? false }
    var children: [Any] { object.accessibilityChildren?() ?? [] }
    func press() -> Bool { object.accessibilityPerformPress?() ?? false }
}
