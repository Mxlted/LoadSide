import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import LoadSideCore
import SwiftUI

enum LibrarySharingMode: String, CaseIterable, Identifiable {
    case automaticHTTPS = "Automatic HTTPS"
    case localDownloads = "Local downloads only"
    case customHTTPS = "My HTTPS server"
    var id: Self { self }
}

@MainActor
final class LocalLibraryModel: ObservableObject {
    @Published private(set) var apps: [LocalAppRecord] = []
    @Published private(set) var session: LocalAppServerSession?
    @Published private(set) var isUpdating = false
    @Published private(set) var isChangingServer = false
    @Published private(set) var serverStatus = ""
    @Published var notice: String?
    @Published var sharingMode: LibrarySharingMode = .automaticHTTPS
    @Published var port = "8787"
    @Published var httpsBaseURL = ""
    private var updateCount = 0 {
        didSet { isUpdating = updateCount > 0 }
    }
    private let store = LocalAppLibrary()
    private let installer = CloudflaredInstaller()
    private var server: LocalAppServer?
    private var tunnel: LocalAppTunnel?
    private var startupTask: Task<Void, Never>?
    private var generation: UUID?
    private var isStopping = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var needsShutdown: Bool { session != nil || isChangingServer }

    init() { Task { await refresh() } }

    func refresh() async {
        do {
            let catalog = try await store.library()
            apps = catalog.apps
            if !catalog.issues.isEmpty { notice = catalog.issues.joined(separator: "\n") }
        } catch { notice = "The app library could not be loaded: \(error.localizedDescription)" }
    }

    func add(_ result: SigningResult) async {
        updateCount += 1
        defer { updateCount -= 1 }
        do {
            _ = try await store.add(result)
            await refresh()
        } catch { notice = "The export is saved, but could not be added to the library: \(error.localizedDescription)" }
    }

    func addPreviousExports(_ results: [SigningResult]) async {
        guard !isUpdating else { return }
        updateCount += 1
        defer { updateCount -= 1 }
        var failures: [String] = []
        var hashes = Set(apps.map(\.sha256))
        for result in results where !hashes.contains(result.sha256) {
            do { _ = try await store.add(result); hashes.insert(result.sha256) }
            catch { failures.append("\(result.displayName): \(error.localizedDescription)") }
        }
        await refresh()
        if !failures.isEmpty { notice = failures.joined(separator: "\n") }
    }

    func remove(_ app: LocalAppRecord) async {
        guard !isUpdating else { return }
        updateCount += 1
        defer { updateCount -= 1 }
        do { try await store.remove(app.id); await refresh() }
        catch { notice = "The library copy could not be removed: \(error.localizedDescription)" }
    }

    func start() {
        guard !isChangingServer, session == nil else { return }
        guard let selectedPort = UInt16(port), selectedPort > 0 else {
            notice = "Choose a port between 1 and 65535."
            return
        }
        let address = sharingMode == .customHTTPS ? httpsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let baseURL = address.isEmpty ? nil : URL(string: address)
        guard sharingMode != .customHTTPS || (baseURL?.scheme == "https" && baseURL?.host?.isEmpty == false) else {
            notice = "Enter the HTTPS address of your server."; return
        }
        let id = UUID(), mode = sharingMode
        generation = id
        isChangingServer = true
        notice = nil
        let onFailure: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                self.notice = "Sharing stopped: \(message)"
                await self.stop()
            }
        }
        let server = LocalAppServer(library: store, onFailure: onFailure)
        let tunnel = LocalAppTunnel(onFailure: onFailure)
        self.server = server; self.tunnel = tunnel
        startupTask = Task {
            do {
                let executable: URL?
                if mode == .automaticHTTPS {
                    serverStatus = "Preparing HTTPS helper…"
                    executable = try await installer.executable()
                } else { executable = nil }
                try Task.checkCancellation()
                serverStatus = "Starting local server…"
                var ready = try await server.start(port: selectedPort, httpsBaseURL: baseURL)
                if let executable {
                    serverStatus = "Connecting HTTPS…"
                    let origin = try await tunnel.start(executable: executable, port: ready.port)
                    try Task.checkCancellation()
                    ready = try await server.configureHTTPS(baseURL: origin, expectedLocalURL: ready.localURL)
                }
                try Task.checkCancellation()
                if generation == id { session = ready }
            } catch {
                await tunnel.stop()
                await server.stop()
                if generation == id, !(error is CancellationError) {
                    notice = "Sharing could not start: \(error.localizedDescription)"
                }
            }
            if generation == id {
                startupTask = nil
                isChangingServer = false
                serverStatus = ""
            }
        }
    }

    func stop() async {
        if isStopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        isStopping = true
        generation = nil
        isChangingServer = true
        serverStatus = "Stopping sharing…"
        let startup = startupTask
        startup?.cancel()
        await startup?.value
        await tunnel?.stop()
        await server?.stop()
        startupTask = nil; tunnel = nil; server = nil
        session = nil
        serverStatus = ""
        isChangingServer = false
        isStopping = false
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func revealLibrary() { NSWorkspace.shared.open(store.directoryURL) }
    func copyAddress() {
        guard let session else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.browserURL.absoluteString, forType: .string)
    }
}

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
                Button { library.revealLibrary() } label: { Label("Show Folder", systemImage: "folder") }
            }
            HStack(alignment: .top, spacing: 20) {
                catalog.frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    VStack(spacing: 16) {
                        serverPanel
                        if let notice = library.notice {
                            InlineNotice(message: notice)
                            Button("Dismiss") { library.notice = nil }.buttonStyle(.borderless)
                        }
                    }
                }.frame(width: 350)
            }
        }
        .padding(AppMetrics.pagePadding)
        .task { await library.refresh() }
    }

    private var catalog: some View {
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
                EmptyState(symbol: "square.stack.3d.up", title: "Your next export appears here",
                           description: "Successfully signed exports are added automatically. You can also add completed exports from Activity using the menu above.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(library.apps) { app in
                            Panel(padding: 15) {
                                HStack(alignment: .top, spacing: 14) {
                                    SymbolTile(symbol: "app.badge.checkmark", size: 42)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(app.displayName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                        Text(app.bundleIdentifier).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(app.byteCount), countStyle: .file)) · \(app.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.system(size: 12)).foregroundStyle(.secondary)
                                        if app.bundleVersion == nil {
                                            Text("Download only · export again for install metadata").font(.system(size: 12)).foregroundStyle(Palette.warning)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Menu {
                                        Button("Remove Library Copy", role: .destructive) { Task { await library.remove(app) } }
                                            .disabled(library.isUpdating)
                                    } label: {
                                        Image(systemName: "ellipsis").frame(width: AppMetrics.iconButtonSize, height: AppMetrics.iconButtonSize)
                                    }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(app.displayName)")
                                }
                            }
                        }
                    }.padding(.bottom, 4)
                }
            }
            if library.isUpdating { ProgressView("Updating library…").controlSize(.regular) }
            Text("Library copies are stored privately. Removing one keeps your original export.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var serverPanel: some View {
        Panel(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SymbolTile(symbol: "network", color: library.session == nil ? .secondary : Palette.success, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local server").font(.headline)
                        Text(library.isChangingServer ? library.serverStatus : library.session == nil ? "Sharing is off" : "Sharing is on")
                            .font(.system(size: 12)).foregroundStyle(library.session == nil ? Color.secondary : Palette.success)
                    }
                    Spacer()
                }
                if let session = library.session {
                    Text(session.installEnabled ? "Open this address in Safari on your iPhone or iPad, then tap Install on device. Keep LoadSide open." : "Open this address on a device on the same network to download apps. Keep LoadSide open.")
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
                    Text(session.installEnabled ? "The device must be eligible for the signed app. An install link does not verify installation or launch." : "For Install buttons, stop sharing and select Automatic HTTPS.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Button("Stop Sharing", role: .destructive) { Task { await library.stop() } }
                        .disabled(library.isChangingServer)
                } else {
                    sharingSetup
                    if library.isChangingServer {
                        ProgressView(library.serverStatus).controlSize(.regular).font(.system(size: 13))
                        Button("Cancel Setup") { Task { await library.stop() } }
                    } else {
                        Button(action: library.start) {
                            Label("Start Sharing", systemImage: "antenna.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(library.apps.isEmpty || library.isUpdating)
                    }
                }
                Divider()
                Text("Anyone with the link can download the library. Stop Sharing or quit LoadSide to invalidate its links. Local HTTP addresses are unencrypted.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var sharingSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Connection", selection: $library.sharingMode) {
                ForEach(LibrarySharingMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }.pickerStyle(.menu)
            switch library.sharingMode {
            case .automaticHTTPS:
                Text("Install from your browser without configuring a server. On first use, LoadSide downloads and verifies Cloudflare’s HTTPS helper (about 20 MB). No account or domain is needed.")
                Text("Starting sharing makes this library reachable through Cloudflare. App downloads pass through their network; signing files stay on your Mac. Internet access is required. The temporary address changes each session.")
                    .foregroundStyle(.secondary)
            case .localDownloads:
                Text("Browse and download on the same network. No external service is used. Direct installation requires an HTTPS connection.")
                    .foregroundStyle(.secondary)
            case .customHTTPS:
                TextField("https://apps.example.com", text: $library.httpsBaseURL).textFieldStyle(.roundedBorder)
                Text("Point your reverse proxy at this Mac’s port and forward the full path. Its HTTPS certificate must be trusted by your device.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Local port")
                TextField("8787", text: $library.port).textFieldStyle(.roundedBorder).frame(width: 90)
                Spacer()
            }
        }.font(.system(size: 13)).disabled(library.isChangingServer)
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
