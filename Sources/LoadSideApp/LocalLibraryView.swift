import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import LoadSideCore
import SwiftUI

struct LocalLibraryView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var library: LocalLibraryModel
    @State private var showAddresses = false

    init(model: WorkspaceModel) {
        self.model = model
        library = model.localLibrary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                PageHeading(title: "Local Library", detail: "Your signed apps, ready to share from this Mac.")
                Spacer()
                Button {
                    library.revealLibrary()
                } label: {
                    Label("Show Folder", systemImage: "folder")
                }
            }
            GeometryReader { geometry in
                if geometry.size.width < 900 {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if !library.apps.isEmpty || library.session != nil || library.isChangingServer {
                                sharing
                                catalog(compact: true)
                            } else {
                                catalog(compact: true)
                                sharing
                            }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        catalog(compact: false).frame(maxWidth: .infinity, maxHeight: .infinity)
                        ScrollView { sharing }.frame(width: 340)
                    }
                }
            }
        }
        .padding(AppMetrics.pagePadding)
        .task { await library.refresh() }
    }

    private var sharing: some View {
        VStack(alignment: .leading, spacing: 16) {
            serverPanel
            if let notice = library.notice {
                InlineNotice(message: notice)
                Button("Dismiss") { library.notice = nil }.buttonStyle(.borderless)
            }
        }
    }

    private func catalog(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(library.apps.count) signed \(library.apps.count == 1 ? "app" : "apps")").font(.headline)
                Spacer()
                Menu {
                    Button("Add Completed Exports from Activity") {
                        Task { await library.addPreviousExports(model.history.filter { $0.status == .completed }.compactMap(\.result)) }
                    }.disabled(library.isUpdating || model.history.allSatisfy { $0.result == nil })
                    Button("Refresh Library") { Task { await library.refresh() } }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: AppMetrics.iconButtonSize, height: AppMetrics.iconButtonSize)
                }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Library actions")
            }
            if library.apps.isEmpty {
                LibraryEmptyState(model: model).frame(minHeight: compact ? 250 : nil)
            } else {
                if compact {
                    appList
                } else {
                    ScrollView { appList }
                }
            }
            if library.isUpdating { ProgressView("Updating library…").controlSize(.regular) }
            Text("Library copies are stored privately. Removing one keeps your original export.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var appList: some View {
        LazyVStack(spacing: 10) {
            ForEach(library.apps) { app in
                Panel(padding: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        SymbolTile(symbol: "app.badge.checkmark", size: 40)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.displayName).font(.system(size: 15, weight: .semibold)).lineLimit(2).help(app.displayName)
                            Text(app.bundleIdentifier).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(app.bundleIdentifier)
                            Text(
                                "\(ByteCountFormatter.string(fromByteCount: Int64(app.byteCount), countStyle: .file)) · \(app.createdAt.formatted(date: .abbreviated, time: .shortened))"
                            )
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if app.bundleVersion == nil {
                                Text("Download only · export again for install metadata").font(.system(size: 12))
                                    .foregroundStyle(Palette.warning)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Menu {
                            Button("Remove Library Copy", role: .destructive) { Task { await library.remove(app) } }
                                .disabled(library.isUpdating)
                        } label: {
                            Image(systemName: "ellipsis").frame(
                                width: AppMetrics.iconButtonSize, height: AppMetrics.iconButtonSize)
                        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(app.displayName)")
                    }
                }
            }
        }.padding(.bottom, 4)
    }

    private var serverPanel: some View {
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SymbolTile(symbol: "network", color: library.session == nil ? .secondary : Palette.success, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Share your library").font(.headline)
                        Text(library.isChangingServer ? library.serverStatus : library.session == nil ? "Sharing is off" : "Sharing is on")
                            .font(.system(size: 12)).foregroundStyle(library.session == nil ? Color.secondary : Palette.success)
                    }
                    Spacer()
                }
                if let session = library.session {
                    Text(
                        session.installEnabled
                            ? "Open this address in Safari on your iPhone or iPad, then tap Install on device. Keep LoadSide open."
                            : "Open this address on a device on the same network to download apps. Keep LoadSide open."
                    )
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text(session.browserURL.absoluteString)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.field, in: RoundedRectangle(cornerRadius: 9))
                    HStack {
                        Button("Copy Link", action: library.copyAddress)
                        Button("Open") { NSWorkspace.shared.open(session.browserURL) }
                    }
                    ShareQRCode(url: session.browserURL)
                    DisclosureGroup("Other addresses", isExpanded: $showAddresses) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("On this Mac: \(session.localURL.absoluteString)")
                            ForEach(session.networkURLs, id: \.self) { url in Text(url.absoluteString) }
                        }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
                    }.font(.system(size: 12))
                    Text(
                        session.installEnabled
                            ? "The device must be eligible for the signed app. An install link does not verify installation or launch."
                            : "For Install buttons, stop sharing and select Automatic HTTPS."
                    )
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    sharingPrivacyNotice
                    Button("Stop Sharing", role: .destructive) { Task { await library.stop() } }
                        .disabled(library.isChangingServer)
                } else {
                    sharingSetup
                    sharingPrivacyNotice
                    if library.isChangingServer {
                        ProgressView(library.serverStatus).controlSize(.regular).font(.system(size: 13))
                        Button("Cancel Setup") { Task { await library.stop() } }
                    } else {
                        Button(action: library.start) {
                            Label("Start Sharing", systemImage: "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(library.apps.isEmpty || library.isUpdating)
                        if library.apps.isEmpty {
                            Text("Add a signed app to your library to start sharing.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var sharingPrivacyNotice: some View {
        Label(
            "Anyone with the link can download your library. Stop Sharing or quit LoadSide to invalidate its links. Local HTTP addresses are unencrypted.",
            systemImage: "link"
        )
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var sharingSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Connection", selection: $library.sharingMode) {
                ForEach(LibrarySharingMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }.pickerStyle(.menu)
            switch library.sharingMode {
            case .automaticHTTPS:
                Text("Install from Safari using a temporary HTTPS link. No account or domain is needed.")
                Text(
                    "Starting sharing makes this library internet-accessible through Cloudflare. App downloads pass through their network; signing files stay on your Mac."
                )
                .foregroundStyle(.secondary)
                DisclosureGroup("Connection details") {
                    Text(
                        "On first use, LoadSide downloads and verifies Cloudflare’s HTTPS helper (about 20 MB). Internet access is required. The temporary address changes each session."
                    ).foregroundStyle(.secondary).padding(.top, 6)
                }
            case .localDownloads:
                Text(
                    "Browse and download on the same network. No external service is used. Direct installation requires an HTTPS connection."
                )
                .foregroundStyle(.secondary)
            case .customHTTPS:
                TextField("https://apps.example.com", text: $library.httpsBaseURL).inputField().accessibilityLabel("HTTPS server address")
                Text(
                    "Point your reverse proxy at this Mac’s port and forward the full path. Its HTTPS certificate must be trusted by your device."
                )
                .foregroundStyle(.secondary)
            }
            HStack {
                Text("Local port")
                TextField("8787", text: $library.port).inputField().frame(width: 90).accessibilityLabel("Local sharing port")
                Spacer()
            }
        }.font(.system(size: 13)).disabled(library.isChangingServer)
    }
}

struct LibraryEmptyState: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        EmptyState(
            symbol: "square.stack.3d.up", title: "Your next export appears here",
            description:
                "Sign an app in the workspace to add it here automatically, or add a completed export from Activity using the menu above.",
            actionTitle: "Open Workspace",
            action: {
                model.jobMode = .sign
                model.section = .workspace
            }
        )
        .disabled(model.isRunning || model.isManagingSigningProfiles)
    }
}

private struct ShareQRCode: View {
    let url: URL
    private var image: CGImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(url.absoluteString.utf8)
        generator.correctionLevel = "M"
        guard let output = generator.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
    var body: some View {
        if let image {
            HStack(spacing: 14) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
                    .frame(width: 132, height: 132).padding(9).background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Text("Scan with your device’s camera to open the library.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.accessibilityLabel("QR code for the sharing address shown above")
        }
    }
}
