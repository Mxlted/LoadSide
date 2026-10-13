import Foundation

/// Safely prepares an unsigned IPA for signing later with another job or tool.
public struct InjectionEngine: Sendable {
    public init() {}

    public func run(_ request: InjectionRequest, onEvent: @escaping @Sendable (SigningEvent) -> Void) async throws -> InjectionExportResult {
        try await run(request, workspaceRoot: FileManager.default.temporaryDirectory, onEvent: onEvent)
    }

    // A private parent directory can be supplied by tests to verify cleanup deterministically.
    func run(_ request: InjectionRequest, workspaceRoot: URL, onEvent: @escaping @Sendable (SigningEvent) -> Void) async throws -> InjectionExportResult {
        func emit(_ stage: SigningStage, _ fraction: Double, _ message: String, _ level: SigningEvent.Level = .info) {
            onEvent(SigningEvent(stage: stage, fraction: fraction, message: message, level: level))
        }
        try Self.validate(request)
        try Task.checkCancellation()
        let fm = FileManager.default
        let workspace = workspaceRoot.appendingPathComponent("LoadSide-injection-\(UUID().uuidString)")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workspace) }
        emit(.preparing, 0.02, "Creating a private injection workspace. No signing credentials are used.")
        let extracted = workspace.appendingPathComponent("archive", isDirectory: true)
        try Archive.extract(request.ipa, to: extracted)
        emit(.inspecting, 0.15, "Inspecting the application and every executable slice.")
        let app = try BundleInventory.mainApp(in: extracted)
        var warnings = try BundleInventory.removeEmbeddedExtensions(in: app, enabled: request.removeExtensions)
        let bundles = try BundleInventory.discover(in: app)
        guard let main = bundles.first(where: { $0.url == app }) else {
            throw LoadSideError("ipa.main", "The main app has no valid Info.plist and executable.")
        }
        try BundleInventory.validateMachO(in: app)
        if let name = request.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            var info = main.info
            info["CFBundleDisplayName"] = name
            try BundleInventory.writeInfo(info, to: app)
            try BundleInventory.updateLocalizedNames(in: app, name: name)
        }
        emit(.injecting, 0.30, "Extracting packages and resolving injected library dependencies.")
        let injection = try Injection.inject(inputs: request.injections, into: app, executable: main.executable, workspace: workspace, filterBundleIdentifier: main.identifier)
        warnings += injection.warnings
        emit(.strippingSignatures, 0.58, "Removing invalidated code signatures and embedded provisioning profiles.")
        try await Self.removeSignatures(in: app)
        let unsignedWarning = "UNSIGNED: this archive requires signing before installation on a standard iOS device. Existing signatures, embedded profiles, and signature entitlements were removed; signing must restore the app's required authorized capabilities."
        warnings.append(unsignedWarning)
        for warning in warnings { emit(.validating, 0.72, warning, .warning) }
        emit(.validating, 0.75, "Rechecking prepared code and confirming that every Mach-O is unsigned.")
        try BundleInventory.validateMachO(in: app)
        try BundleInventory.ensureExecutablePermissions(in: app)
        _ = try BundleInventory.discover(in: app)
        for binary in try BundleInventory.contents(app) where MachO.isMachO(binary) {
            guard try !MachO.inspect(binary).hasCodeSignature else {
                throw LoadSideError("injection.signature", "Could not confirm that \(binary.lastPathComponent) is unsigned.")
            }
        }
        emit(.exporting, 0.90, "Packaging the unsigned IPA for signing later.")
        let staging = request.output.deletingLastPathComponent().appendingPathComponent(".LoadSide-\(UUID().uuidString).ipa")
        defer { try? fm.removeItem(at: staging) }
        try Archive.createIPA(from: extracted, to: staging)
        let hash = try SigningEngine.sha256(staging)
        let info = try BundleInventory.readInfo(app.appendingPathComponent("Info.plist"))
        try Task.checkCancellation()
        try SigningEngine.commit(staging: staging, destination: request.output)
        emit(.completed, 1, "Unsigned IPA exported. Signing is still required before device installation.")
        return InjectionExportResult(output: request.output, bundleIdentifier: main.identifier,
            displayName: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent,
            injectedLibraryCount: injection.injectedLibraries.count, warnings: warnings, sha256: hash)
    }

    static func validate(_ request: InjectionRequest) throws {
        guard !request.injections.isEmpty else {
            throw LoadSideError("injection.inputs", "Add at least one DEB, dylib, or framework to inject.")
        }
        guard request.ipa.isFileURL, try request.ipa.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LoadSideError("request.ipa", "The source IPA must be a regular local file.")
        }
        guard request.output.isFileURL, request.output.pathExtension.lowercased() == "ipa" else {
            throw LoadSideError("request.output", "Choose a local output file ending in .ipa.")
        }
        guard !FileManager.default.fileExists(atPath: request.output.path) else {
            throw LoadSideError("output.exists", "An output file already exists at this destination.", recovery: "Choose another output name. LoadSide never overwrites an existing export.")
        }
        for input in [request.ipa] + request.injections {
            guard input.isFileURL, FileManager.default.isReadableFile(atPath: input.path) else {
                throw LoadSideError("request.input", "Cannot read input \(input.lastPathComponent).")
            }
            guard input.resolvingSymlinksInPath() != request.output.resolvingSymlinksInPath() else {
                throw LoadSideError("request.outputInput", "The output cannot replace a source file.")
            }
        }
    }

    private static func removeSignatures(in app: URL) async throws {
        let runner = ProcessRunner()
        for binary in try BundleInventory.contents(app) where MachO.isMachO(binary) {
            // Tool diagnostics include untrusted filenames. Only the parsed load
            // commands establish that every architecture is already unsigned.
            guard try MachO.inspect(binary).hasCodeSignature else { continue }
            let removed = try await runner.run("/usr/bin/codesign", ["--remove-signature", binary.path], check: false)
            guard removed.status == 0 else {
                throw LoadSideError("injection.removeSignature", "Could not remove the signature from \(binary.lastPathComponent): \(removed.diagnostic)")
            }
        }
        let directories = [app] + (try BundleInventory.contents(app).filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        })
        for directory in directories {
            try Task.checkCancellation()
            let isBundle = ["app", "appex", "framework", "bundle", "xpc"].contains(directory.pathExtension.lowercased())
            let hasSeal = (try? directory.appendingPathComponent("_CodeSignature").resourceValues(forKeys: [.isSymbolicLinkKey])) != nil
            let names = ["_CodeSignature"] + (isBundle || hasSeal ? ["CodeResources", "embedded.mobileprovision", "embedded.provisionprofile"] : [])
            for name in names {
                let artifact = directory.appendingPathComponent(name)
                // resourceValues detects symlinks too, including dangling ones after a seal is removed.
                if (try? artifact.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil {
                    try FileManager.default.removeItem(at: artifact)
                }
            }
        }
    }
}
