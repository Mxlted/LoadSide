import AppKit
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
    private let store: LocalAppLibrary
    private let installer: CloudflaredInstaller
    private var server: LocalAppServer?
    private var tunnel: LocalAppTunnel?
    private var startupTask: Task<Void, Never>?
    private var initialLoadTask: Task<Void, Never>?
    private var generation: UUID?
    private var isStopping = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var needsShutdown: Bool { session != nil || isChangingServer }

    init(store: LocalAppLibrary = LocalAppLibrary(), installer: CloudflaredInstaller = CloudflaredInstaller()) {
        self.store = store
        self.installer = installer
        initialLoadTask = Task { await refresh() }
    }

    func waitForInitialLoad() async { await initialLoadTask?.value }

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
            do {
                _ = try await store.add(result)
                hashes.insert(result.sha256)
            } catch { failures.append("\(result.displayName): \(error.localizedDescription)") }
        }
        await refresh()
        if !failures.isEmpty { notice = failures.joined(separator: "\n") }
    }

    func remove(_ app: LocalAppRecord) async {
        guard !isUpdating else { return }
        updateCount += 1
        defer { updateCount -= 1 }
        do {
            try await store.remove(app.id)
            await refresh()
        } catch { notice = "The library copy could not be removed: \(error.localizedDescription)" }
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
            notice = "Enter the HTTPS address of your server."
            return
        }
        let id = UUID()
        let mode = sharingMode
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
        self.server = server
        self.tunnel = tunnel
        startupTask = Task {
            do {
                let executable: URL?
                if mode == .automaticHTTPS {
                    serverStatus = "Preparing HTTPS helper…"
                    executable = try await installer.executable()
                } else {
                    executable = nil
                }
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
        startupTask = nil
        tunnel = nil
        server = nil
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
