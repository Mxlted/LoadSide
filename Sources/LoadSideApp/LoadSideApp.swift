import AppKit
import SwiftUI

@main
struct LoadSideApp: App {
    @StateObject private var model = WorkspaceModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            StudioView(model: model)
                .preferredColorScheme(.dark)
                .tint(Studio.mint)
                .frame(minWidth: 1080, minHeight: 740)
                .onOpenURL { model.accept([$0]) }
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add IPA…", action: model.chooseIPA).keyboardShortcut("o").disabled(model.isRunning)
                Button("New Signing Session", action: model.reset).keyboardShortcut("n").disabled(model.isRunning)
            }
            CommandMenu("Signing") {
                Button("Sign & Export…", action: model.beginSigning).keyboardShortcut("r").disabled(!model.canSign)
                Button("Cancel Signing", action: model.cancel).keyboardShortcut(".").disabled(!model.isRunning || model.isCancelling)
                Divider()
                Button("Add Certificate…", action: model.chooseCertificate).disabled(model.isRunning)
                Button("Add Provisioning Profiles…", action: model.chooseProfiles).disabled(model.isRunning)
                Button("Add Injection…", action: model.chooseInjections).disabled(model.isRunning)
            }
            CommandGroup(replacing: .help) {
                Button("LoadSide Guide") { model.section = .guide }
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

struct StudioView: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Studio.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Studio.line).frame(height: 1)
                Group {
                    switch model.section {
                    case .workspace: WorkspaceView(model: model)
                    case .activity: ActivityView(model: model)
                    case .guide: GuideView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Studio.background)
        }
        .background(Studio.background)
        .alert("Unable to complete action", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(Studio.mint)
                    Image(systemName: "arrow.up.doc.fill").font(.system(size: 21, weight: .semibold)).foregroundStyle(Studio.background)
                }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LoadSide").font(.system(size: 19, weight: .bold))
                    Text("SIGNING STUDIO").font(.system(size: 8, weight: .semibold)).tracking(2.1).foregroundStyle(Studio.muted)
                }
            }.padding(.top, 39).padding(.bottom, 40)
            Text("LIBRARY").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(Studio.muted).padding(.leading, 12).padding(.bottom, 13)
            ForEach(AppSection.allCases) { section in
                Button { model.section = section } label: {
                    HStack(spacing: 12) {
                        Image(systemName: section.symbol).font(.system(size: 14)).frame(width: 18)
                        Text(section.rawValue).font(.system(size: 12, weight: model.section == section ? .semibold : .medium))
                        Spacer()
                        if section == .activity, !model.history.isEmpty {
                            Text("\(model.history.count)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Studio.muted)
                        }
                        if model.section == section { RoundedRectangle(cornerRadius: 2).fill(Studio.mint).frame(width: 3, height: 13) }
                    }
                    .foregroundStyle(model.section == section ? Studio.mint : Studio.muted)
                    .padding(.horizontal, 12).padding(.vertical, 13)
                    .background(model.section == section ? Studio.mint.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).padding(.bottom, 5)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "lock.shield").font(.system(size: 20, weight: .light)).foregroundStyle(Studio.mint)
                Text("Your keys. Your machine.").font(.system(size: 12, weight: .semibold))
                Text("Signing happens locally. Your certificates and apps stay with you.")
                    .font(.system(size: 11)).foregroundStyle(Studio.muted).lineSpacing(4)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(Studio.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
            HStack {
                Text("LOADSIDE").font(.system(size: 8, weight: .semibold)).tracking(1.2)
                Spacer()
                Text(Bundle.main.infoDictionary?["LoadSideVersion"] as? String ?? "0.1.0-rc.1").font(.system(size: 10, design: .monospaced))
            }.foregroundStyle(Studio.muted.opacity(0.65)).padding(.top, 23).padding(.bottom, 23).padding(.horizontal, 3)
        }.padding(.horizontal, 18).frame(width: 208).background(Studio.sidebar)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: model.section.symbol).foregroundStyle(Studio.muted)
                Text("Studio").foregroundStyle(Studio.muted)
                Text("/").foregroundStyle(Studio.muted.opacity(0.5))
                Text(model.section.rawValue).foregroundStyle(.white.opacity(0.9))
            }.font(.system(size: 11))
            Spacer()
            Circle().fill(model.isRunning ? Studio.mint : Studio.muted).frame(width: 5, height: 5)
            Text(model.isRunning ? "SIGNING IN PROGRESS" : "LOCAL WORKSPACE")
                .font(.system(size: 9, weight: .medium)).tracking(1.2).foregroundStyle(Studio.muted)
        }.padding(.horizontal, 30).frame(height: 68)
    }
}
