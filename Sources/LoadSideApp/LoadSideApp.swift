import AppKit
import SwiftUI

@main
struct LoadSideApp: App {
    @StateObject private var model = WorkspaceModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("LoadSide") {
            MainView(model: model)
                .tint(Palette.accent)
                .frame(minWidth: 960, minHeight: 680)
                .onOpenURL { model.accept([$0]) }
                .onAppear { delegate.model = model }
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1120, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open IPA…", action: model.chooseIPA).keyboardShortcut("o").disabled(model.isRunning)
                Button("New Signing Session", action: model.reset).keyboardShortcut("n").disabled(model.isRunning || model.isManagingSigningProfiles)
            }
            CommandMenu("Signing") {
                Button("Sign & Export…", action: model.beginSigning).keyboardShortcut("r").disabled(!model.canSign)
                Button("Cancel Signing", action: model.cancel).keyboardShortcut(".").disabled(!model.isRunning || model.isCancelling)
                Divider()
                Button("Import Certificate…", action: model.chooseCertificate).disabled(model.isRunning)
                Button("Add Provisioning Profiles…", action: model.chooseProfiles).disabled(model.isRunning)
                Button("Add Injection…", action: model.chooseInjections).disabled(model.isRunning)
                Divider()
                Button("Signing Profiles") { model.section = .signingProfiles }.keyboardShortcut("2")
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
        guard model?.isRunning == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A signing operation is still running"
        alert.informativeText = "Keep LoadSide open while it finishes, or cancel the operation before quitting."
        alert.addButton(withTitle: "Keep Signing")
        alert.addButton(withTitle: "Cancel Operation")
        if alert.runModal() == .alertSecondButtonReturn { model?.cancel() }
        return .terminateCancel
    }
}

struct MainView: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch model.section {
                case .workspace: WorkspaceView(model: model)
                case .signingProfiles: SigningProfilesView(model: model)
                case .activity: ActivityView(model: model)
                case .guide: GuideView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.background)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Text(model.section == .workspace ? (model.ipaInspection?.displayName ?? model.ipa?.deletingPathExtension().lastPathComponent ?? "Sign an app") : model.section.rawValue)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if model.isRunning {
                        ProgressView().controlSize(.mini)
                        Text(model.isCancelling ? "Cancelling…" : "Signing…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { model.reset() } label: { Image(systemName: "doc.badge.plus") }
                    .help("New signing session (⌘N)").accessibilityLabel("New signing session").disabled(model.isRunning || model.isManagingSigningProfiles)
            }
        }
        .alert("Unable to complete action", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "signature").font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.accent)
                    .frame(width: 29, height: 29).background(Palette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                Text("LoadSide").font(.system(size: 15, weight: .semibold))
            }.padding(.horizontal, 9).padding(.top, 17).padding(.bottom, 24)
            ForEach(AppSection.allCases) { section in
                Button { model.section = section } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol).font(.system(size: 14)).frame(width: 20)
                        Text(section.rawValue).font(.system(size: 12, weight: model.section == section ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if section == .activity, model.isRunning { Circle().fill(Palette.accent).frame(width: 5, height: 5) }
                    }
                    .foregroundStyle(model.section == section ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(model.section == section ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(model.section == section ? .isSelected : [])
            }
            Spacer()
            VStack(alignment: .leading, spacing: 5) {
                Label("Local signing", systemImage: "lock").font(.system(size: 10))
                Text(Bundle.main.infoDictionary?["LoadSideVersion"] as? String ?? "0.1.0-rc.2").font(.system(size: 10, design: .monospaced))
            }.foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.bottom, 18)
        }.padding(.horizontal, 10).frame(width: 172).frame(maxHeight: .infinity).background(.ultraThinMaterial)
    }
}
