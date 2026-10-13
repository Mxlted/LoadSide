import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import LoadSideCore
import SwiftUI

@MainActor
final class LocalLibraryModel: ObservableObject {
    @Published private(set) var apps: [LocalAppRecord] = []
    @Published private(set) var session: LocalAppServerSession?
    @Published private(set) var isUpdating = false
    @Published private(set) var isChangingServer = false
    @Published var notice: String?
    @Published var port = "8787"
    @Published var httpsBaseURL = ""
    private var updateCount = 0 {
        didSet { isUpdating = updateCount > 0 }
    }
    private let store = LocalAppLibrary()
    private lazy var server = LocalAppServer(library: store, onFailure: { [weak self] message in
        Task { @MainActor [weak self] in
            self?.session = nil
            self?.notice = "Sharing stopped: \(message)"
        }
    })

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

    func start() async {
        guard !isChangingServer, session == nil else { return }
        guard let selectedPort = UInt16(port), selectedPort > 0 else {
            notice = "Choose a port between 1 and 65535."
            return
        }
        let address = httpsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = address.isEmpty ? nil : URL(string: address)
        guard address.isEmpty || baseURL != nil else { notice = "Enter a valid HTTPS address."; return }
        isChangingServer = true
        defer { isChangingServer = false }
        do {
            notice = nil
            session = try await server.start(port: selectedPort, httpsBaseURL: baseURL)
        } catch { notice = "The local server could not start: \(error.localizedDescription)" }
    }

    func stop() async {
        guard !isChangingServer else { return }
        isChangingServer = true
        await server.stop()
        session = nil
        isChangingServer = false
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
    @State private var showHTTPS = false
    @State private var showAddresses = false

    init(model: WorkspaceModel) {
        self.model = model
        library = model.localLibrary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                PageHeading(title: "Local Library", detail: "Your signed apps, ready to share from this Mac.")
                Spacer()
                Button { library.revealLibrary() } label: { Label("Show Folder", systemImage: "folder") }
            }
            HStack(alignment: .top, spacing: 18) {
                catalog.frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    VStack(spacing: 14) {
                        serverPanel
                        if let notice = library.notice {
                            InlineNotice(message: notice)
                            Button("Dismiss") { library.notice = nil }.buttonStyle(.borderless)
                        }
                    }
                }.frame(width: 310)
            }
        }
        .padding(22)
        .task { await library.refresh() }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(library.apps.count) signed \(library.apps.count == 1 ? "app" : "apps")").font(.headline)
                Spacer()
                Menu {
                    Button("Add Completed Exports from Activity") {
                        Task { await library.addPreviousExports(model.history.filter { $0.status == .completed }.compactMap(\.result)) }
                    }.disabled(library.isUpdating || model.history.allSatisfy { $0.result == nil })
                    Button("Refresh Library") { Task { await library.refresh() } }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
            if library.apps.isEmpty {
                EmptyState(symbol: "square.stack.3d.up", title: "Your next export appears here",
                           description: "Successfully signed exports are added automatically. You can also add completed exports from Activity using the menu above.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(library.apps) { app in
                            Panel(padding: 14) {
                                HStack(alignment: .top, spacing: 12) {
                                    SymbolTile(symbol: "app.badge.checkmark", size: 38)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(app.displayName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                        Text(app.bundleIdentifier).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(app.byteCount), countStyle: .file)) · \(app.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                        if app.bundleVersion == nil {
                                            Text("Download only · export again for install metadata").font(.caption).foregroundStyle(Palette.warning)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Menu {
                                        Button("Remove Library Copy", role: .destructive) { Task { await library.remove(app) } }
                                            .disabled(library.isUpdating)
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                                }
                            }
                        }
                    }.padding(.bottom, 4)
                }
            }
            if library.isUpdating { ProgressView("Updating library…").controlSize(.small) }
            Text("Library copies are stored privately. Removing one keeps your original export.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var serverPanel: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SymbolTile(symbol: "network", color: library.session == nil ? .secondary : Palette.success, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local server").font(.headline)
                        Text(library.session == nil ? "Sharing is off" : "Sharing is on")
                            .font(.caption).foregroundStyle(library.session == nil ? Color.secondary : Palette.success)
                    }
                    Spacer()
                }
                if let session = library.session {
                    Text("Open this address on your iPhone or iPad on the same network. Keep LoadSide open.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(session.browserURL.absoluteString)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.field, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Copy Link", action: library.copyAddress)
                        Button("Open") { NSWorkspace.shared.open(session.browserURL) }
                    }
                    ShareQRCode(url: session.browserURL)
                    DisclosureGroup("Other addresses", isExpanded: $showAddresses) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("On this Mac: \(session.localURL.absoluteString)")
                            ForEach(session.networkURLs, id: \.self) { url in Text(url.absoluteString) }
                        }.font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(.top, 6)
                    }.font(.caption)
                    Text(session.installEnabled ? "Install links use your HTTPS address. The device must trust its certificate and be eligible for the signed app." : "Browsing and downloads are available. To enable Install buttons, stop sharing and configure HTTPS below.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Stop Sharing", role: .destructive) { Task { await library.stop() } }
                        .disabled(library.isChangingServer)
                } else {
                    Text("Share your signed app catalog with devices on your local network.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        Text("Port").font(.system(size: 12))
                        TextField("8787", text: $library.port).textFieldStyle(.roundedBorder).frame(width: 82)
                        Spacer()
                    }
                    DisclosureGroup("Enable browser installation", isExpanded: $showHTTPS) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HTTPS address").font(.caption.weight(.medium))
                            TextField("https://apps.example.com", text: $library.httpsBaseURL).textFieldStyle(.roundedBorder)
                            Text("Point a reverse proxy at this Mac’s local port. Its HTTPS certificate must be trusted by your iOS device. LoadSide generates the install manifests; it does not configure the proxy or upload apps.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }.font(.system(size: 12))
                    Button { Task { await library.start() } } label: {
                        Label(library.isChangingServer ? "Starting…" : "Start Sharing", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(library.isChangingServer || library.apps.isEmpty || library.isUpdating)
                }
                Divider()
                Text("Anyone with the link can download the library. Use a trusted network; local HTTP traffic is unencrypted. Stopping sharing invalidates its links.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
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
            HStack(spacing: 12) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
                    .frame(width: 120, height: 120).padding(8).background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Scan with your device’s camera to open the library.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.accessibilityLabel("QR code for the sharing address shown above")
        }
    }
}
