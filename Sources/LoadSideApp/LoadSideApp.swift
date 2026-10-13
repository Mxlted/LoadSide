import AppKit
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace", signingProfiles = "Signing Profiles", library = "Local Library", activity = "Activity", guide = "Help"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .workspace: "signature"
        case .library: "network"
        case .signingProfiles: "person.crop.rectangle.stack"
        case .activity: "clock.arrow.circlepath"
        case .guide: "questionmark.circle"
        }
    }
}

@main
struct LoadSideApp: App {
    @StateObject private var model = WorkspaceModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("LoadSide") {
            MainView(model: model)
                .tint(Palette.accent)
                .font(.system(size: 14))
                .controlSize(.regular)
                .frame(minWidth: AppMetrics.minimumWindowSize.width, minHeight: AppMetrics.minimumWindowSize.height)
                .onOpenURL { model.accept([$0]) }
                .onAppear { delegate.model = model }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: AppMetrics.defaultWindowSize.width, height: AppMetrics.defaultWindowSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open IPA…", action: model.chooseIPA).keyboardShortcut("o").disabled(model.isRunning)
                Button("New Session", action: model.reset).keyboardShortcut("n").disabled(
                    model.isRunning || model.isManagingSigningProfiles)
            }
            CommandMenu("Workflow") {
                Button(model.jobMode == .sign ? "Sign & Export…" : "Inject & Export…", action: model.beginSigning).keyboardShortcut("r")
                    .disabled(!model.canSign)
                Button("Cancel Export", action: model.cancel).keyboardShortcut(".").disabled(!model.isRunning || model.isCancelling)
                Divider()
                Button("Import Certificate…", action: model.chooseCertificate).disabled(model.isRunning)
                Button("Add Provisioning Profiles…", action: model.chooseProfiles).disabled(model.isRunning)
                Button("Add Injection…", action: model.chooseInjections).disabled(model.isRunning)
                Divider()
                Button("Workspace") { model.section = .workspace }.keyboardShortcut("1")
                Button("Signing Profiles") { model.section = .signingProfiles }.keyboardShortcut("2")
                Button("Local Library") { model.section = .library }.keyboardShortcut("3")
                Button("Activity") { model.section = .activity }.keyboardShortcut("4")
            }
            CommandGroup(replacing: .help) {
                Button("LoadSide Help") { model.section = .guide }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.isRunning == true else {
            guard let library = model?.localLibrary, library.needsShutdown else { return .terminateNow }
            Task {
                await library.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        let alert = NSAlert()
        alert.messageText = "An export is still running"
        alert.informativeText = "Keep LoadSide open while it finishes, or cancel the operation before quitting."
        alert.addButton(withTitle: "Keep Exporting")
        alert.addButton(withTitle: "Cancel Operation")
        if alert.runModal() == .alertSecondButtonReturn { model?.cancel() }
        return .terminateCancel
    }
}

struct MainView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var sidebarSelection: AppSection?

    init(model: WorkspaceModel) {
        self.model = model
        _sidebarSelection = State(initialValue: model.section)
    }

    private var title: String {
        model.section == .workspace
            ? (model.ipaInspection?.displayName ?? model.ipa?.deletingPathExtension().lastPathComponent ?? "Prepare an app")
            : model.section.rawValue
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: AppMetrics.sidebarWidth, max: 260)
        } detail: {
            // Keep destination ideal sizes from moving the native split view
            // outside its viewport when the selected screen changes.
            GeometryReader { detailGeometry in
                ZStack(alignment: .topLeading) {
                    switch model.section {
                    case .workspace: WorkspaceView(model: model)
                    case .signingProfiles: SigningProfilesView(model: model)
                    case .library: LocalLibraryView(model: model)
                    case .activity: ActivityView(model: model)
                    case .guide: GuideView()
                    }
                }
                .frame(width: detailGeometry.size.width, height: detailGeometry.size.height, alignment: .topLeading)
            }
            .background(Palette.background)
            .navigationTitle(title)
            .toolbar { workspaceToolbar }
        }
        .navigationSplitViewStyle(.balanced)
        // Native List selection can be delivered while AppKit updates its rows.
        // Commit model navigation from SwiftUI's change phase, not that callback.
        .onChange(of: sidebarSelection) { _, section in
            if let section, model.section != section { model.section = section }
        }
        .onChange(of: model.section) { _, section in sidebarSelection = section }
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .alert("Unable to complete action", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }

    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        if model.isRunning {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.mini)
                    Text(model.isCancelling ? "Cancelling…" : model.jobMode == .sign ? "Signing…" : "Injecting…").font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        ToolbarItem(placement: .automatic) {
            Button {
                model.reset()
            } label: {
                Label("New Session", systemImage: "doc.badge.plus")
            }
            .help("New session (⌘N)").accessibilityLabel("New session")
            .disabled(model.isRunning || model.isManagingSigningProfiles)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $sidebarSelection) {
                ForEach(AppSection.allCases) { section in
                    navigationRow(section)
                }
            }
            .listStyle(.sidebar)
            HStack(spacing: 7) {
                Image(systemName: "lock.shield").accessibilityHidden(true)
                Text("Prepared on your Mac")
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(16)
        }
        .navigationTitle("LoadSide")
    }

    private func navigationRow(_ section: AppSection) -> some View {
        NavigationLink(value: section) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol).frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: model.section == section ? .semibold : .regular))
                Spacer(minLength: 0)
                if section == .activity, model.isRunning {
                    ProgressView().controlSize(.mini).accessibilityLabel("Export in progress")
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .tag(section)
        .accessibilityIdentifier("navigation.\(section)")
        .accessibilityAddTraits(model.section == section ? .isSelected : [])
    }
}
