import Foundation
import CryptoKit
import Darwin

public struct SigningEngine: Sendable {
    public init() {}

    public func run(_ request: SigningRequest, onEvent: @escaping @Sendable (SigningEvent) -> Void) async throws -> SigningResult {
        func emit(_ stage: SigningStage, _ fraction: Double, _ message: String, _ level: SigningEvent.Level = .info) {
            onEvent(SigningEvent(stage: stage, fraction: fraction, message: message, level: level))
        }
        let fm = FileManager.default
        emit(.preparing, 0.01, "Creating a private signing workspace.")
        try Self.validate(request)
        let workspace = fm.temporaryDirectory.appendingPathComponent("LoadSide-job-\(UUID().uuidString)")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: workspace) }
        let extracted = workspace.appendingPathComponent("archive", isDirectory: true)
        try Task.checkCancellation()
        try Archive.extract(request.ipa, to: extracted)
        emit(.inspecting, 0.09, "Inspecting the app, extensions, and every executable slice.")
        let mainApp = try BundleInventory.mainApp(in: extracted)
        var warnings = try BundleInventory.removeEmbeddedExtensions(in: mainApp, enabled: request.removeExtensions)
        for warning in warnings { emit(.inspecting, 0.10, warning, .warning) }
        var bundles = try BundleInventory.discover(in: mainApp)
        guard let main = bundles.first(where: { $0.url == mainApp }) else { throw LoadSideError("ipa.main", "The main app has no valid Info.plist and executable.") }
        try BundleInventory.validateMachO(in: mainApp)
        let runner = ProcessRunner()
        var originalEntitlements: [URL: [String: Any]] = [:]
        for bundle in bundles where bundle.requiresProfile {
            let result = try await runner.run("/usr/bin/codesign", ["--display", "--entitlements", "-", "--xml", bundle.url.path], check: false)
            if result.status != 0 {
                guard result.diagnostic.contains("not signed at all") else { throw LoadSideError("entitlements.read", "Could not inspect the original entitlements of \(bundle.identifier): \(result.diagnostic)") }
                originalEntitlements[bundle.url] = [:]
                warnings.append("\(bundle.identifier) is unsigned; only minimum identity entitlements can be derived. Original capabilities cannot be recovered from an unsigned binary.")
            } else if result.stdout.isEmpty {
                originalEntitlements[bundle.url] = [:]
            } else {
                guard let entitlements = try PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any] else { throw LoadSideError("entitlements.format", "Existing entitlements are malformed in \(bundle.identifier).") }
                originalEntitlements[bundle.url] = entitlements
            }
        }
        emit(.credentials, 0.18, "Validating profile CMS signatures and certificate membership.")
        let profiles = try request.profiles.map { try Task.checkCancellation(); return try ProvisioningProfile.inspect($0) }
        let identity = try SigningIdentity(p12: request.certificate, password: request.password, workspace: workspace, profiles: profiles)
        // Explicit lifetime keeps the private keychain available throughout codesign calls.
        defer { withExtendedLifetime(identity) {} }
        emit(.credentials, 0.25, "Validated signing identity: \(identity.name).")
        let identifierPlan = try SigningPreflight.resolveForSigning(original: main.identifier, profiles: profiles, certificate: identity.certificate,
                                                                   policy: request.bundleIdentifierPolicy, override: request.bundleIdentifier)
        if identifierPlan.changesIdentifier {
            try BundleInventory.rewriteIdentifiers(in: bundles, original: main.identifier, replacement: identifierPlan.effectiveIdentifier)
            let warning = "Changed bundle identifier \(main.identifier) → \(identifierPlan.effectiveIdentifier) to match the selected profile. Prefix-related nested identifiers follow this change; existing app data and runtime bundle-identifier checks are not migrated."
            warnings.append(warning)
            emit(.credentials, 0.27, warning, .warning)
        }
        if let name = request.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            var info = try BundleInventory.readInfo(main.url.appendingPathComponent("Info.plist"))
            info["CFBundleDisplayName"] = name
            try BundleInventory.writeInfo(info, to: main.url)
            try BundleInventory.updateLocalizedNames(in: main.url, name: name)
        }
        bundles = try BundleInventory.discover(in: mainApp)
        guard let updatedMain = bundles.first(where: { $0.url == mainApp }) else { throw LoadSideError("ipa.main", "The main app could not be read after metadata updates.") }
        emit(.entitlements, 0.30, "Matching a profile and resolving entitlements for each app and extension.")
        var entitlementFiles: [URL: URL] = [:]
        var teams = Set<String>()
        for (index, bundle) in bundles.filter(\.requiresProfile).enumerated() {
            try Task.checkCancellation()
            let profile: ProvisioningProfile
            do {
                profile = try ProvisioningProfile.select(from: profiles, bundleIdentifier: bundle.identifier, certificate: identity.certificate)
            } catch let error as LoadSideError where error.code == "profile.noMatch" {
                if bundle.url.pathExtension.lowercased() == "appex" {
                    throw LoadSideError("profile.extensionNoMatch", "The retained extension \(bundle.identifier) has no matching profile for the selected certificate. The main app’s profile does not automatically authorize extension IDs.", recovery: "Add a profile for this extension, or explicitly enable Remove Extensions to omit extension functionality. The original IPA will remain unchanged.")
                }
                if bundle.url != mainApp {
                    throw LoadSideError("profile.nestedAppNoMatch", "Nested app \(bundle.identifier) needs its own matching profile for the selected certificate.", recovery: "Add a matching profile for this nested app. Remove Extensions does not remove nested apps such as Watch apps.")
                }
                throw error
            }
            let executableInfo = try MachO.inspect(bundle.executable)
            guard executableInfo.slices.allSatisfy({ $0.platform.map { profile.supports(machOPlatform: $0) } ?? true }) else {
                throw LoadSideError("profile.platform", "Profile “\(profile.name)” does not authorize the Mach-O platform of \(bundle.identifier).")
            }
            if let supported = bundle.info["CFBundleSupportedPlatforms"] as? [String] {
                let expected: [String: UInt32] = ["iPhoneOS": 2, "WatchOS": 4, "AppleTVOS": 3, "XROS": 11]
                guard supported.allSatisfy({ expected[$0].map { profile.supports(machOPlatform: $0) } ?? false }) else {
                    throw LoadSideError("profile.platform", "Profile “\(profile.name)” does not authorize the platform of \(bundle.identifier).")
                }
            }
            guard profile.provisionsAllDevices || profile.deviceCount > 0 else {
                throw LoadSideError("profile.appStore", "Profile “\(profile.name)” is an App Store profile and cannot authorize direct installation.", recovery: "Use a Development, Ad Hoc, or Enterprise profile for sideloading.")
            }
            teams.insert(profile.teamIdentifier)
            let resolved = try EntitlementResolver.resolve(requested: originalEntitlements[bundle.url] ?? [:], profile: profile, bundleIdentifier: bundle.identifier, policy: request.entitlementPolicy)
            warnings += resolved.warnings
            let entitlementFile = workspace.appendingPathComponent("entitlements-\(index).plist")
            try PropertyListSerialization.data(fromPropertyList: resolved.values, format: .xml, options: 0).write(to: entitlementFile, options: .atomic)
            entitlementFiles[bundle.url] = entitlementFile
            try profile.data.write(to: bundle.url.appendingPathComponent("embedded.mobileprovision"), options: .atomic)
            emit(.entitlements, 0.31 + 0.08 * Double(index + 1) / Double(bundles.count), "\(bundle.identifier) → \(profile.name)")
        }
        guard teams.count == 1, let team = teams.first else { throw LoadSideError("profile.teams", "All app and extension profiles must belong to one developer team.") }
        var injectedCount = 0
        if !request.injections.isEmpty {
            emit(.injecting, 0.40, "Extracting packages and resolving injected library dependencies.")
            if main.identifier != updatedMain.identifier {
                emit(.injecting, 0.40, "DEB bundle filters use the original identifier \(main.identifier). Runtime bundle-identifier checks inside injected code are not rewritten.")
            }
            let injection = try Injection.inject(inputs: request.injections, into: mainApp, executable: updatedMain.executable, workspace: workspace, filterBundleIdentifier: main.identifier)
            injectedCount = injection.injectedLibraries.count
            warnings += injection.warnings
        }
        // Re-inspect after injection: all newly added binaries are included in the sign graph.
        try BundleInventory.validateMachO(in: mainApp)
        try BundleInventory.ensureExecutablePermissions(in: mainApp)
        let targets = try BundleInventory.signingTargets(in: mainApp)
        warnings.append("Certificate/profile checks are offline. Apple revocation status and device installation eligibility are not verified by export.")
        for warning in warnings { emit(.entitlements, 0.46, warning, .warning) }
        let diagnosticRoot = extracted.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for (index, target) in targets.enumerated() {
            try Task.checkCancellation()
            let diagnosticPath = target.resolvingSymlinksInPath().standardizedFileURL.path
            let displayPath = diagnosticPath.hasPrefix(diagnosticRoot) ? String(diagnosticPath.dropFirst(diagnosticRoot.count)) : target.lastPathComponent
            emit(.signing, 0.48 + 0.30 * Double(index) / Double(max(1, targets.count)), "Signing \(displayPath)")
            var arguments = ["--force", "--sign", identity.fingerprint, "--keychain", identity.keychainURL.path, "--timestamp=none", "--generate-entitlement-der"]
            if let file = entitlementFiles[target] { arguments += ["--entitlements", file.path] }
            arguments.append(target.path)
            _ = try await runner.run("/usr/bin/codesign", arguments)
        }
        emit(.verifying, 0.80, "Verifying each nested signature and the sealed application resources.")
        for (index, target) in targets.enumerated() {
            _ = try await runner.run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", target.path])
            emit(.verifying, 0.80 + 0.10 * Double(index + 1) / Double(max(1, targets.count)), "Verified \(target.lastPathComponent)")
        }
        // The signature must contain exactly the resolved claims, including DER generation.
        for (target, file) in entitlementFiles {
            let verified = try await runner.run("/usr/bin/codesign", ["--display", "--entitlements", "-", "--xml", target.path])
            let actual = try PropertyListSerialization.propertyList(from: verified.stdout, format: nil) as? NSDictionary
            let expected = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? NSDictionary
            guard let actual, let expected, actual == expected else { throw LoadSideError("verify.entitlements", "Signed entitlements do not match the resolved claims for \(target.lastPathComponent).") }
        }
        emit(.exporting, 0.92, "Packaging and committing the signed IPA.")
        // Build beside the destination so the final exclusive rename is atomic on its volume.
        let staging = request.output.deletingLastPathComponent().appendingPathComponent(".LoadSide-\(UUID().uuidString).ipa")
        defer { try? fm.removeItem(at: staging) }
        try Archive.createIPA(from: extracted, to: staging)
        let hash = try Self.sha256(staging)
        try Task.checkCancellation()
        try Self.commit(staging: staging, destination: request.output)
        emit(.completed, 1, "Export complete. Every code object passed local signature verification.")
        return SigningResult(output: request.output, bundleIdentifier: updatedMain.identifier,
                             displayName: updatedMain.info["CFBundleDisplayName"] as? String ?? updatedMain.info["CFBundleName"] as? String ?? updatedMain.url.deletingPathExtension().lastPathComponent,
                             certificateName: identity.name, teamIdentifier: team, signedCodeCount: targets.count,
                             injectedLibraryCount: injectedCount, warnings: warnings, sha256: hash)
    }

    static func validate(_ request: SigningRequest) throws {
        guard !request.profiles.isEmpty else { throw LoadSideError("request.profiles", "Add at least one provisioning profile.") }
        guard request.ipa.isFileURL, try request.ipa.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LoadSideError("request.ipa", "The source IPA must be a regular local file.") }
        guard request.output.isFileURL, request.output.pathExtension.lowercased() == "ipa" else { throw LoadSideError("request.output", "Choose a local output file ending in .ipa.") }
        guard !FileManager.default.fileExists(atPath: request.output.path) else { throw LoadSideError("output.exists", "An output file already exists at this destination.", recovery: "Choose another output name. LoadSide never overwrites an existing export.") }
        if let identifier = request.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty {
            try SigningPreflight.validateIdentifier(identifier)
        }
        for input in [request.ipa, request.certificate] + request.profiles + request.injections {
            guard input.isFileURL, FileManager.default.isReadableFile(atPath: input.path) else { throw LoadSideError("request.input", "Cannot read input \(input.lastPathComponent).") }
            guard input.resolvingSymlinksInPath() != request.output.resolvingSymlinksInPath() else { throw LoadSideError("request.outputInput", "The output cannot replace a source file.") }
        }
    }

    static func commit(staging: URL, destination: URL) throws {
        guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw LoadSideError("output.commit", "Could not atomically create the export: \(String(cString: strerror(errno))).", recovery: "Choose a writable destination and a filename that does not already exist.")
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty { try Task.checkCancellation(); hash.update(data: chunk) }
        return hash.finalize().hex
    }
}

struct CodeBundle {
    let url: URL
    let executable: URL
    let identifier: String
    let info: [String: Any]
    var requiresProfile: Bool { ["app", "appex"].contains(url.pathExtension.lowercased()) }
}

enum BundleInventory {
    static func mainApp(in extracted: URL) throws -> URL {
        let payload = extracted.appendingPathComponent("Payload", isDirectory: true)
        let payloadType = try payload.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard payloadType.isDirectory == true, payloadType.isSymbolicLink != true else { throw LoadSideError("ipa.payload", "Payload must be a real directory.") }
        let apps = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey]).filter { $0.pathExtension.lowercased() == "app" }
        guard apps.count == 1, let mainApp = apps.first else { throw LoadSideError("ipa.payload", "An IPA must contain exactly one top-level Payload/*.app.") }
        let mainType = try mainApp.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard mainType.isDirectory == true, mainType.isSymbolicLink != true else { throw LoadSideError("ipa.payload", "The top-level app must be a real directory.") }
        return mainApp
    }

    static func ensureExecutablePermissions(in app: URL) throws {
        // ZIPs produced on filesystems without Unix permissions can lose +x.
        // Normalize only actual staged code, never unrelated resource files.
        for binary in try contents(app) where MachO.isMachO(binary) {
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
    }

    /// The explicit option applies only to app-extension bundles in the staged
    /// copy. Retained nested apps, including Watch apps, still require profiles.
    static func removeEmbeddedExtensions(in app: URL, enabled: Bool) throws -> [String] {
        guard enabled else { return [] }
        let candidates = try contents(app).filter {
            guard $0.pathExtension.lowercased() == "appex" else { return false }
            return try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.sorted { $0.pathComponents.count > $1.pathComponents.count }
        var warnings: [String] = []
        for bundle in candidates {
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: bundle)
            warnings.append("Removed embedded extension \(bundle.lastPathComponent) from the staged app because Remove Extensions was enabled. Its functionality will be absent from this export.")
        }
        return warnings
    }

    static func discover(in app: URL) throws -> [CodeBundle] {
        let directories = [app] + (try contents(app)).filter { ["app", "appex", "framework", "bundle", "xpc"].contains($0.pathExtension.lowercased()) }
        var result: [CodeBundle] = []
        for url in directories {
            guard (try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true else { continue }
            let requiresExecutable = ["app", "appex", "framework", "xpc"].contains(url.pathExtension.lowercased())
            let plist = url.appendingPathComponent("Info.plist")
            guard FileManager.default.fileExists(atPath: plist.path) else {
                if requiresExecutable { throw LoadSideError("bundle.info", "Missing Info.plist in \(url.lastPathComponent).") }
                continue
            }
            let info = try readInfo(plist)
            guard let executable = info["CFBundleExecutable"] as? String else {
                if requiresExecutable { throw LoadSideError("bundle.executable", "Missing CFBundleExecutable in \(url.lastPathComponent).") }
                continue
            }
            // Empty executable strings also occur in resource-only .bundle
            // products. Classify them before validating code-only metadata.
            if !requiresExecutable && executable.isEmpty { continue }
            guard !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"), !executable.utf8.contains(0) else { throw LoadSideError("bundle.metadata", "Invalid bundle metadata in \(url.lastPathComponent).") }
            let binary = url.appendingPathComponent(executable)
            // Resource-only bundles commonly retain a build-generated executable
            // name even though no executable is shipped. Their enclosing code
            // bundle seals these resources; they are not independent code targets.
            if url.pathExtension.lowercased() == "bundle", !FileManager.default.fileExists(atPath: binary.path) { continue }
            guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else { throw LoadSideError("bundle.metadata", "Invalid bundle identifier in \(url.lastPathComponent).") }
            guard binary.resolvingSymlinksInPath().path.hasPrefix(url.resolvingSymlinksInPath().path + "/"), MachO.isMachO(binary) else { throw LoadSideError("bundle.executable", "\(url.lastPathComponent) does not contain the expected Mach-O executable.") }
            result.append(CodeBundle(url: url, executable: binary.resolvingSymlinksInPath(), identifier: identifier, info: info))
        }
        let identifiers = result.filter(\.requiresProfile).map(\.identifier)
        guard Set(identifiers).count == identifiers.count else { throw LoadSideError("bundle.duplicateID", "Two app or extension bundles use the same identifier.") }
        return result
    }

    static func contents(_ root: URL) throws -> [URL] {
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, error in failure = error; return false }) else { throw LoadSideError("bundle.enumeration", "Cannot inspect app contents.") }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
            urls.append(url)
        }
        if let failure { throw failure }
        return urls
    }

    static func validateMachO(in root: URL) throws {
        for url in try contents(root) where MachO.isMachO(url) {
            let info = try MachO.inspect(url)
            guard !info.isEncrypted else { throw LoadSideError("ipa.encrypted", "\(url.lastPathComponent) contains encrypted executable code.", recovery: "Supply an unsigned or re-signable IPA whose executable slices are already decrypted.") }
            guard info.slices.allSatisfy({ [2, 6, 8].contains($0.fileType) }) else { throw LoadSideError("macho.type", "Unsupported embedded Mach-O file type in \(url.lastPathComponent).") }
            guard info.slices.allSatisfy({ $0.cpuType == 12 || $0.cpuType == 0x0100000c || $0.cpuType == 0x0200000c }) else { throw LoadSideError("macho.architecture", "\(url.lastPathComponent) contains a simulator or unsupported architecture.") }
            guard info.slices.allSatisfy({ $0.platform.map { [2, 3, 4, 11].contains($0) } ?? true }) else { throw LoadSideError("macho.platform", "\(url.lastPathComponent) targets macOS or a simulator instead of a device.") }
        }
    }

    static func signingTargets(in root: URL) throws -> [URL] {
        let bundles = try discover(in: root)
        let bundleBinaries = Set(bundles.map(\.executable))
        let binaries = try contents(root).filter { MachO.isMachO($0) && !bundleBinaries.contains($0.resolvingSymlinksInPath()) }
        return Array(Set(binaries + bundles.map(\.url))).sorted {
            $0.pathComponents.count == $1.pathComponents.count ? $0.path < $1.path : $0.pathComponents.count > $1.pathComponents.count
        }
    }

    static func rewriteIdentifiers(in bundles: [CodeBundle], original: String, replacement: String) throws {
        func replacementID(_ value: String) -> String {
            if value == original { return replacement }
            if value.hasPrefix(original + ".") { return replacement + value.dropFirst(original.count) }
            return value
        }
        func updateReferences(_ dictionary: [String: Any]) -> [String: Any] {
            var result = dictionary
            for (key, value) in dictionary {
                if ["CFBundleIdentifier", "WKCompanionAppBundleIdentifier", "WKAppBundleIdentifier"].contains(key), let string = value as? String { result[key] = replacementID(string) }
                else if let nested = value as? [String: Any] { result[key] = updateReferences(nested) }
            }
            return result
        }
        for bundle in bundles where bundle.requiresProfile { try writeInfo(updateReferences(bundle.info), to: bundle.url) }
    }

    static func writeInfo(_ info: [String: Any], to bundle: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: bundle.appendingPathComponent("Info.plist"), options: .atomic)
    }

    static func readInfo(_ plist: URL) throws -> [String: Any] {
        guard (try plist.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else { throw LoadSideError("bundle.infoSize", "\(plist.lastPathComponent) exceeds the 16 MB metadata limit.") }
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any] else { throw LoadSideError("bundle.info", "Invalid bundle metadata in \(plist.lastPathComponent).") }
        return info
    }

    static func updateLocalizedNames(in app: URL, name: String) throws {
        for directory in try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: [.isDirectoryKey]) where directory.pathExtension == "lproj" {
            let file = directory.appendingPathComponent("InfoPlist.strings")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var values = try readInfo(file)
            guard values["CFBundleDisplayName"] != nil else { continue }
            values["CFBundleDisplayName"] = name
            try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: file, options: .atomic)
        }
    }
}
