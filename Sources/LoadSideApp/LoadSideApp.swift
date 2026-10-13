import AppKit
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace", library = "Local Library", signingProfiles = "Signing Profiles", activity = "Activity", guide = "Help"
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
                .controlSize(.large)
                .frame(minWidth: AppMetrics.minimumWindowSize.width, minHeight: AppMetrics.minimumWindowSize.height)
                .onOpenURL { model.accept([$0]) }
                .onAppear { delegate.model = model }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: AppMetrics.defaultWindowSize.width, height: AppMetrics.defaultWindowSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open IPA…", action: model.chooseIPA).keyboardShortcut("o").disabled(model.isRunning)
                Button("New Session", action: model.reset).keyboardShortcut("n").disabled(model.isRunning || model.isManagingSigningProfiles)
            }
            CommandMenu("Workflow") {
                Button(model.jobMode == .sign ? "Sign & Export…" : "Inject & Export…", action: model.beginSigning).keyboardShortcut("r").disabled(!model.canSign)
                Button("Cancel Export", action: model.cancel).keyboardShortcut(".").disabled(!model.isRunning || model.isCancelling)
                Divider()
                Button("Import Certificate…", action: model.chooseCertificate).disabled(model.isRunning)
                Button("Add Provisioning Profiles…", action: model.chooseProfiles).disabled(model.isRunning)
                Button("Add Injection…", action: model.chooseInjections).disabled(model.isRunning)
                Divider()
                Button("Signing Profiles") { model.section = .signingProfiles }.keyboardShortcut("2")
                Button("Local Library") { model.section = .library }.keyboardShortcut("3")
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
    @State private var sidebarVisible = true

    private var title: String {
        model.section == .workspace
            ? (model.ipaInspection?.displayName ?? model.ipa?.deletingPathExtension().lastPathComponent ?? "Prepare an app")
            : model.section.rawValue
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar.frame(width: AppMetrics.sidebarWidth)
                Divider()
            }
            ZStack(alignment: .topLeading) {
                switch model.section {
                case .workspace: WorkspaceView(model: model)
                case .signingProfiles: SigningProfilesView(model: model)
                case .library: LocalLibraryView(model: model)
                case .activity: ActivityView(model: model)
                case .guide: GuideView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
        }
        .background(Palette.background)
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .navigationTitle(title)
        .toolbar { workspaceToolbar }
        .alert("Unable to complete action", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { sidebarVisible.toggle() } label: { Label("Toggle Sidebar", systemImage: "sidebar.left") }
                .help(sidebarVisible ? "Hide sidebar" : "Show sidebar")
        }
        if model.isRunning {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.mini)
                    Text(model.isCancelling ? "Cancelling…" : model.jobMode == .sign ? "Signing…" : "Injecting…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
        ToolbarItem(placement: .automatic) {
            Button { model.reset() } label: { Label("New Session", systemImage: "doc.badge.plus") }
                .help("New session (⌘N)").accessibilityLabel("New session")
                .disabled(model.isRunning || model.isManagingSigningProfiles)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 11) {
                SymbolTile(symbol: "signature", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LoadSide").font(.system(size: 18, weight: .semibold))
                    Text("Your app workspace").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 7).padding(.top, 9)
            VStack(spacing: 6) {
                ForEach(AppSection.allCases) { section in
                    Button { model.section = section } label: {
                        HStack(spacing: 11) {
                            Image(systemName: section.symbol).frame(width: 22)
                            Text(section.rawValue).font(.system(size: 13, weight: model.section == section ? .semibold : .regular)).lineLimit(1)
                            Spacer(minLength: 0)
                            if section == .activity, model.isRunning {
                                ProgressView().controlSize(.mini).accessibilityLabel("Export in progress")
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 11)
                        .foregroundStyle(model.section == section ? Color.primary : Color.secondary)
                        .background(model.section == section ? Palette.accent.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 11))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.section == section ? .isSelected : [])
                }
            }
            .padding(7)
            .floatingControlSurface(cornerRadius: 18)
            Spacer(minLength: 13)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.shield").font(.system(size: 14)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prepared on your Mac").font(.system(size: 12, weight: .medium))
                    Text(Bundle.main.infoDictionary?["LoadSideVersion"] as? String ?? "0.1.0-rc.2")
                        .font(.system(size: 11, design: .monospaced))
                }
            }.foregroundStyle(.secondary).padding(.horizontal, 9).padding(.bottom, 4)
        }
        .padding(13)
        .frame(maxHeight: .infinity)
    }
}
