import Foundation

struct CodeBundle {
    let url: URL
    let executable: URL
    let identifier: String
    let info: [String: Any]
    var requiresProfile: Bool { ["app", "appex"].contains(url.pathExtension.lowercased()) }
}

/// Discovers and validates staged bundle contents shared by inspection and both job engines.
enum BundleInventory {
    static func mainApp(in extracted: URL) throws -> URL {
        let payload = extracted.appendingPathComponent("Payload", isDirectory: true)
        let payloadType = try payload.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard payloadType.isDirectory == true, payloadType.isSymbolicLink != true else {
            throw LoadSideError("ipa.payload", "Payload must be a real directory.")
        }
        let apps = try FileManager.default.contentsOfDirectory(
            at: payload, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        ).filter { url in
            guard url.pathExtension.lowercased() == "app" else { return false }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            // Finder can include a regular ._App.app AppleDouble sidecar beside
            // App.app. It is metadata, not a second application. Directories and
            // links with that name still undergo the normal app validation.
            return !(url.lastPathComponent.hasPrefix("._") && values.isRegularFile == true && values.isSymbolicLink != true)
        }
        guard apps.count == 1, let mainApp = apps.first else {
            throw LoadSideError("ipa.payload", "An IPA must contain exactly one top-level Payload/*.app.")
        }
        let mainType = try mainApp.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard mainType.isDirectory == true, mainType.isSymbolicLink != true else {
            throw LoadSideError("ipa.payload", "The top-level app must be a real directory.")
        }
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
            warnings.append(
                "Removed embedded extension \(bundle.lastPathComponent) from the staged app because Remove Extensions was enabled. Its functionality will be absent from this export."
            )
        }
        return warnings
    }

    static func discover(in app: URL) throws -> [CodeBundle] {
        let directories =
            [app] + (try contents(app)).filter { ["app", "appex", "framework", "bundle", "xpc"].contains($0.pathExtension.lowercased()) }
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
                if requiresExecutable {
                    throw LoadSideError("bundle.executable", "Missing CFBundleExecutable in \(url.lastPathComponent).")
                }
                continue
            }
            // Empty executable strings also occur in resource-only .bundle
            // products. Classify them before validating code-only metadata.
            if !requiresExecutable && executable.isEmpty { continue }
            guard !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/"), !executable.utf8.contains(0) else {
                throw LoadSideError("bundle.metadata", "Invalid bundle metadata in \(url.lastPathComponent).")
            }
            let binary = url.appendingPathComponent(executable)
            // Resource-only bundles commonly retain a build-generated executable
            // name even though no executable is shipped. Their enclosing code
            // bundle seals these resources; they are not independent code targets.
            if url.pathExtension.lowercased() == "bundle", !FileManager.default.fileExists(atPath: binary.path) { continue }
            guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else {
                throw LoadSideError("bundle.metadata", "Invalid bundle identifier in \(url.lastPathComponent).")
            }
            guard binary.resolvingSymlinksInPath().path.hasPrefix(url.resolvingSymlinksInPath().path + "/"), MachO.isMachO(binary) else {
                throw LoadSideError("bundle.executable", "\(url.lastPathComponent) does not contain the expected Mach-O executable.")
            }
            result.append(CodeBundle(url: url, executable: binary.resolvingSymlinksInPath(), identifier: identifier, info: info))
        }
        let identifiers = result.filter(\.requiresProfile).map(\.identifier)
        guard Set(identifiers).count == identifiers.count else {
            throw LoadSideError("bundle.duplicateID", "Two app or extension bundles use the same identifier.")
        }
        return result
    }

    static func contents(_ root: URL) throws -> [URL] {
        var failure: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else { throw LoadSideError("bundle.enumeration", "Cannot inspect app contents.") }
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
            guard !info.isEncrypted else {
                throw LoadSideError(
                    "ipa.encrypted", "\(url.lastPathComponent) contains encrypted executable code.",
                    recovery: "Supply an unsigned or re-signable IPA whose executable slices are already decrypted.")
            }
            guard info.slices.allSatisfy({ [2, 6, 8].contains($0.fileType) }) else {
                throw LoadSideError("macho.type", "Unsupported embedded Mach-O file type in \(url.lastPathComponent).")
            }
            guard info.slices.allSatisfy({ $0.cpuType == 12 || $0.cpuType == 0x0100000c || $0.cpuType == 0x0200000c }) else {
                throw LoadSideError("macho.architecture", "\(url.lastPathComponent) contains a simulator or unsupported architecture.")
            }
            guard info.slices.allSatisfy({ $0.platform.map { [2, 3, 4, 11].contains($0) } ?? true }) else {
                throw LoadSideError("macho.platform", "\(url.lastPathComponent) targets macOS or a simulator instead of a device.")
            }
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
                if ["CFBundleIdentifier", "WKCompanionAppBundleIdentifier", "WKAppBundleIdentifier"].contains(key),
                    let string = value as? String
                {
                    result[key] = replacementID(string)
                } else if let nested = value as? [String: Any] {
                    result[key] = updateReferences(nested)
                }
            }
            return result
        }
        for bundle in bundles where bundle.requiresProfile { try writeInfo(updateReferences(bundle.info), to: bundle.url) }
    }

    static func writeInfo(_ info: [String: Any], to bundle: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(
            to: bundle.appendingPathComponent("Info.plist"), options: .atomic)
    }

    static func readInfo(_ plist: URL) throws -> [String: Any] {
        guard (try plist.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else {
            throw LoadSideError("bundle.infoSize", "\(plist.lastPathComponent) exceeds the 16 MB metadata limit.")
        }
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any] else {
            throw LoadSideError("bundle.info", "Invalid bundle metadata in \(plist.lastPathComponent).")
        }
        return info
    }

    static func updateLocalizedNames(in app: URL, name: String) throws {
        for directory in try FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: [.isDirectoryKey])
        where directory.pathExtension == "lproj" {
            let file = directory.appendingPathComponent("InfoPlist.strings")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var values = try readInfo(file)
            guard values["CFBundleDisplayName"] != nil else { continue }
            values["CFBundleDisplayName"] = name
            try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: file, options: .atomic)
        }
    }
}
