import Foundation

public struct InjectionResult: Sendable {
    public let injectedLibraries: [URL]
    public let warnings: [String]
}

/// Relocates app-compatible dynamic libraries. It is deliberately not a Debian package installer.
public enum Injection {
    private struct Candidate { let source: URL; let originalPath: String; let relativePath: String; let entryPoint: Bool }
    private static let systemLibraries: Set<String> = [
        "libSystem.B.dylib", "libobjc.A.dylib", "libc++.1.dylib", "libc++abi.dylib", "libz.1.dylib", "libz.dylib",
        "libsqlite3.dylib", "libsqlite3.0.dylib", "libxml2.2.dylib", "libxml2.dylib", "libiconv.2.dylib", "libiconv.dylib",
        "libresolv.9.dylib", "libresolv.dylib", "libcompression.dylib", "libbz2.1.0.dylib", "libbz2.dylib",
        "libnetwork.dylib", "libncurses.5.4.dylib", "libutil.dylib", "libMobileGestalt.dylib", "liblockdown.dylib"
    ]

    public static func inject(inputs: [URL], into appURL: URL, executable: URL, workspace: URL, filterBundleIdentifier: String? = nil) throws -> InjectionResult {
        if inputs.isEmpty { return InjectionResult(injectedLibraries: [], warnings: []) }
        guard inputs.count <= 128 else { throw LoadSideError("injection.limit", "At most 128 injection inputs are supported in one job.") }
        let fm = FileManager.default
        let appInfo = try readPlist(appURL.appendingPathComponent("Info.plist"))
        let bundleID = filterBundleIdentifier ?? (appInfo["CFBundleIdentifier"] as? String ?? "")
        let executableName = executable.lastPathComponent
        let host = try MachO.inspect(executable)
        guard !host.isEncrypted else { throw LoadSideError("injection.encrypted", "Injection requires a decrypted application executable.") }
        let stage = workspace.appendingPathComponent("injection-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var candidates: [Candidate] = [], copies: [(URL, String)] = [], warnings: [String] = []
        var extractedEntries = 0
        var extractedBytes: Int64 = 0
        func extractPackage(_ archive: URL, to destination: URL) throws {
            let remainingEntries = 100_000 - extractedEntries
            let remainingBytes = Int64(16 * 1_024 * 1_024 * 1_024) - extractedBytes
            guard remainingEntries > 0, remainingBytes > 0 else { throw LoadSideError("injection.limit", "Combined Debian payloads exceed safe extraction limits.") }
            let summary = try Archive.extract(archive, to: destination, limits: .init(maximumEntries: remainingEntries, maximumExpandedBytes: remainingBytes))
            extractedEntries += summary.entries; extractedBytes += summary.expandedBytes
        }
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()
            let source = input.resolvingSymlinksInPath()
            let sourceType = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard source.isFileURL, sourceType.isRegularFile == true || (source.pathExtension.lowercased() == "framework" && sourceType.isDirectory == true) else {
                throw LoadSideError("injection.source", "Injection input must be a regular local file or a framework directory.")
            }
            switch source.pathExtension.lowercased() {
            case "dylib":
                candidates.append(Candidate(source: source, originalPath: source.path, relativePath: source.lastPathComponent, entryPoint: true))
                copies.append((source, source.lastPathComponent))
            case "framework":
                let discovered = try frameworkCandidates(source, original: source.path, entryPoint: true)
                candidates += discovered
                copies.append((source, source.lastPathComponent))
            case "deb":
                let package = stage.appendingPathComponent("package-\(index)")
                let handle = try FileHandle(forReadingFrom: source)
                let magic = try handle.read(upToCount: 8); try handle.close()
                guard magic == Data("!<arch>\n".utf8) else { throw LoadSideError("injection.deb", "\(source.lastPathComponent) is not a Debian ar package.") }
                try extractPackage(source, to: package)
                let members = try fm.contentsOfDirectory(at: package, includingPropertiesForKeys: nil)
                let versionFile = package.appendingPathComponent("debian-binary")
                guard (try? versionFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      (try? versionFile.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 <= 8 }) == true,
                      (try? String(contentsOf: versionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == "2.0" else {
                    throw LoadSideError("injection.debVersion", "Unsupported Debian package version in \(source.lastPathComponent).")
                }
                let payloads = members.filter { ["data.tar", "data.tar.gz", "data.tar.bz2", "data.tar.xz", "data.tar.lzma", "data.tar.zst"].contains($0.lastPathComponent) }
                guard payloads.count == 1 else { throw LoadSideError("injection.debPayload", "The package must contain exactly one supported data.tar payload.") }
                let payload = stage.appendingPathComponent("payload-\(index)")
                try extractPackage(payloads[0], to: payload)
                let before = candidates.count
                for prefix in ["", "var/jb/"] {
                    let tweakPath = prefix + "Library/MobileSubstrate/DynamicLibraries"
                    let tweaks = payload.appendingPathComponent(tweakPath)
                    for dylib in try children(tweaks) where dylib.pathExtension.lowercased() == "dylib" {
                        if try !filterMatches(dylib.deletingPathExtension().appendingPathExtension("plist"), bundleID: bundleID, executable: executableName) {
                            warnings.append("Skipped \(dylib.lastPathComponent): its Substrate filter does not target this application.")
                            continue
                        }
                        candidates.append(Candidate(source: dylib, originalPath: "/" + tweakPath + "/" + dylib.lastPathComponent, relativePath: dylib.lastPathComponent, entryPoint: true))
                        copies.append((dylib, dylib.lastPathComponent))
                    }
                    let libraryPath = prefix + "usr/lib"
                    for dylib in try children(payload.appendingPathComponent(libraryPath)) where dylib.pathExtension.lowercased() == "dylib" {
                        candidates.append(Candidate(source: dylib, originalPath: "/" + libraryPath + "/" + dylib.lastPathComponent, relativePath: dylib.lastPathComponent, entryPoint: false))
                        copies.append((dylib, dylib.lastPathComponent))
                    }
                    let frameworkPath = prefix + "Library/Frameworks"
                    for framework in try children(payload.appendingPathComponent(frameworkPath)) where framework.pathExtension.lowercased() == "framework" {
                        candidates += try frameworkCandidates(framework, original: "/" + frameworkPath + "/" + framework.lastPathComponent, entryPoint: false)
                        copies.append((framework, framework.lastPathComponent))
                    }
                    // Preserve ordinary adjacent resource bundles without executing any package script.
                    for base in [tweaks, payload.appendingPathComponent(prefix + "Library/Application Support")] {
                        for bundle in try children(base) where bundle.pathExtension.lowercased() == "bundle" {
                            try validateTree(bundle)
                            copies.append((bundle, bundle.lastPathComponent))
                        }
                    }
                }
                guard candidates.count > before else { throw LoadSideError("injection.noLibraries", "\(source.lastPathComponent) contains no supported libraries targeting this application.", recovery: "Supply a relocatable iOS dylib/framework, or a DEB with matching MobileSubstrate libraries, usr/lib dylibs, or Library/Frameworks content.") }
                if !candidates[before...].contains(where: \.entryPoint) {
                    throw LoadSideError("injection.noEntryPoint", "\(source.lastPathComponent) has no matching MobileSubstrate entry point.", recovery: "For a library-only package, extract and explicitly supply the intended dylib or framework. LoadSide will not guess which dependency should be loaded at application launch.")
                }
                warnings.append("\(source.lastPathComponent): package scripts, daemons, preferences and system installation paths are not installed. Resource bundles are copied under Frameworks; hard-coded resource paths and jailbreak-only runtime behavior are not rewritten.")
            default:
                throw LoadSideError("injection.type", "Unsupported injection input: \(source.lastPathComponent)", recovery: "Choose an iOS .dylib, .framework directory, or a supported .deb package.")
            }
        }
        let frameworkRoot = appURL.appendingPathComponent("Frameworks")
        if fm.fileExists(atPath: frameworkRoot.path) {
            let values = try frameworkRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw LoadSideError("injection.destination", "The application's Frameworks directory is unsafe.") }
        } else { try fm.createDirectory(at: frameworkRoot, withIntermediateDirectories: false) }
        var names = Set<String>(), copyEntries = 0
        var copyBytes: Int64 = 0
        for (source, name) in copies {
            try Task.checkCancellation()
            guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted, !fm.fileExists(atPath: frameworkRoot.appendingPathComponent(name).path) else {
                throw LoadSideError("injection.collision", "Injected content would overwrite or conflict with \(name).", recovery: "Remove the duplicate input or use libraries with unique names.")
            }
            let usage = try validateTree(source)
            copyEntries += usage.entries; copyBytes += usage.bytes
            guard copyEntries <= 100_000, copyBytes <= 16 * 1_024 * 1_024 * 1_024 else { throw LoadSideError("injection.limit", "Combined injection inputs exceed safe file count or size limits.") }
        }
        var aliases: [String: String] = [:]
        var infos: [String: MachOInfo] = [:]
        for candidate in candidates {
            let info = try MachO.inspect(candidate.source)
            guard !info.isEncrypted, info.slices.allSatisfy({ $0.fileType == 6 }) else { throw LoadSideError("injection.binaryType", "\(candidate.source.lastPathComponent) is not an unencrypted Mach-O dynamic library.") }
            try validateArchitectures(info, host: host, name: candidate.source.lastPathComponent)
            let destination = "@executable_path/Frameworks/" + candidate.relativePath
            infos[candidate.relativePath] = info
            let keys = [candidate.originalPath, candidate.source.lastPathComponent] + info.slices.compactMap(\.installName)
            for key in keys {
                if let existing = aliases[key], existing != destination { throw LoadSideError("injection.ambiguous", "Multiple injected libraries share the install name \(key).") }
                aliases[key] = destination
                if key.hasPrefix("/var/jb/") { aliases[String(key.dropFirst(7))] = destination }
            }
        }
        var plans: [(Candidate, [String: String])] = []
        for candidate in candidates {
            guard let info = infos[candidate.relativePath] else { continue }
            var replacements: [String: String] = [:]
            for dependency in Set(info.slices.flatMap(\.dependencies)) {
                // Explicit inputs cannot accidentally shadow known Apple runtime libraries.
                if isSystemDependency(dependency) {
                    if dependency.hasPrefix("/System/Library/PrivateFrameworks/") { warnings.append("\(candidate.source.lastPathComponent) uses the private system dependency \(dependency); availability depends on the device OS.") }
                } else if let destination = aliases[dependency] ?? (allowsNameResolution(dependency) ? aliases[URL(fileURLWithPath: dependency).lastPathComponent] : nil) {
                    replacements[dependency] = destination
                } else if let existing = try existingDependency(dependency, candidate: candidate, info: info, host: host, app: appURL) {
                    let existingInfo = try MachO.inspect(existing)
                    try validateArchitectures(existingInfo, host: host, name: existing.lastPathComponent)
                    replacements[dependency] = "@executable_path/" + String(existing.path.dropFirst(appURL.standardizedFileURL.path.count + 1))
                } else {
                    throw LoadSideError("injection.unresolvedDependency", "\(candidate.source.lastPathComponent) requires an unresolved dependency: \(dependency)", recovery: "Supply the matching app-compatible dependency as another dylib/framework. Substrate, Substitute, libhooker and jailbreak services are not automatically provided.")
                }
            }
            plans.append((candidate, replacements))
        }
        // All source and dependency validation is complete before the application's code is edited.
        for (source, name) in copies { try fm.copyItem(at: source, to: frameworkRoot.appendingPathComponent(name)) }
        var injected: [URL] = []
        for (candidate, replacements) in plans {
            try Task.checkCancellation()
            let target = frameworkRoot.appendingPathComponent(candidate.relativePath)
            try MachO.rewrite(target, dependencies: replacements, installName: "@executable_path/Frameworks/" + candidate.relativePath)
            injected.append(target)
            if candidate.entryPoint { try MachO.addDylib(path: "@executable_path/Frameworks/" + candidate.relativePath, to: executable) }
        }
        return InjectionResult(injectedLibraries: injected, warnings: Array(Set(warnings)).sorted())
    }

    private static func readPlist(_ url: URL) throws -> [String: Any] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        let size = values.fileSize ?? 0, maximum = 16 * 1_024 * 1_024
        guard values.isRegularFile == true, values.isSymbolicLink != true, size > 0, size <= maximum else { throw LoadSideError("injection.plistLimit", "Property list must be a regular file no larger than 16 MiB: \(url.lastPathComponent)") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw LoadSideError("injection.plistLimit", "Property list grew beyond the 16 MiB limit.") }
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw LoadSideError("injection.plist", "Invalid dictionary property list: \(url.lastPathComponent)")
        }
        return result
    }
    private static func children(_ directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    }
    private static func frameworkCandidates(_ framework: URL, original: String, entryPoint: Bool) throws -> [Candidate] {
        try validateTree(framework)
        let infoURL = framework.appendingPathComponent("Info.plist")
        let plist = try readPlist(infoURL)
        guard let executable = plist["CFBundleExecutable"] as? String, !executable.isEmpty,
              !executable.contains("/"), !executable.contains("\\"), executable != ".", executable != ".." else {
            throw LoadSideError("injection.framework", "Framework \(framework.lastPathComponent) has no valid CFBundleExecutable.")
        }
        let binary = framework.appendingPathComponent(executable)
        guard FileManager.default.fileExists(atPath: binary.path) else { throw LoadSideError("injection.framework", "Framework executable is missing: \(executable)") }
        // Versioned macOS framework layouts cannot be embedded as iOS frameworks.
        guard try binary.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LoadSideError("injection.frameworkLayout", "Versioned or symbolic framework executables are unsupported for iOS injection.") }
        if let files = fmFiles(framework) {
            for file in files where file.resolvingSymlinksInPath() != binary.resolvingSymlinksInPath() && MachO.isMachO(file) {
                throw LoadSideError("injection.nestedCode", "Framework contains additional executable code requiring separate dependency validation: \(file.lastPathComponent)")
            }
        }
        return [Candidate(source: binary, originalPath: original + "/" + executable, relativePath: framework.lastPathComponent + "/" + executable, entryPoint: entryPoint)]
    }
    private static func fmFiles(_ directory: URL) -> [URL]? {
        FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { item in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return url
        }
    }
    @discardableResult private static func validateTree(_ source: URL) throws -> (entries: Int, bytes: Int64) {
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        var entries = 1, bytes = Int64(values.isRegularFile == true ? (values.fileSize ?? 0) : 0)
        guard bytes <= 4 * 1_024 * 1_024 * 1_024 else { throw LoadSideError("injection.limit", "Injection file exceeds the 4 GiB input limit.") }
        guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { throw LoadSideError("injection.source", "Injection source must be a real file or directory: \(source.lastPathComponent)") }
        if values.isDirectory == true {
            guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) else { throw LoadSideError("injection.source", "Unable to inspect injection directory.") }
            for case let file as URL in enumerator {
                try Task.checkCancellation()
                let item = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                entries += 1
                if item.isRegularFile == true {
                    let fileBytes = Int64(item.fileSize ?? 0)
                    guard fileBytes <= 4 * 1_024 * 1_024 * 1_024 else { throw LoadSideError("injection.limit", "Injection directory contains a file larger than 4 GiB.") }
                    bytes += fileBytes
                }
                guard entries <= 100_000, bytes <= 16 * 1_024 * 1_024 * 1_024 else { throw LoadSideError("injection.limit", "Injection directory exceeds safe file count or size limits.") }
                if item.isSymbolicLink == true {
                    guard file.resolvingSymlinksInPath().path.hasPrefix(source.resolvingSymlinksInPath().path + "/"), fm.fileExists(atPath: file.path) else { throw LoadSideError("injection.symlink", "Injection directory contains an unsafe symbolic link.") }
                } else if item.isDirectory != true && item.isRegularFile != true { throw LoadSideError("injection.source", "Injection directory contains an unsupported special file.") }
                if source.pathExtension.lowercased() == "bundle", item.isRegularFile == true, MachO.isMachO(file) {
                    throw LoadSideError("injection.nestedCode", "Resource bundles with executable Mach-O code are unsupported: \(file.lastPathComponent)")
                }
                if file != source, ["framework", "dylib", "appex", "app"].contains(file.pathExtension.lowercased()) {
                    throw LoadSideError("injection.nestedCode", "Nested code inside an injected framework or resource bundle requires separate supported inputs: \(file.lastPathComponent)")
                }
            }
        }
        return (entries, bytes)
    }
    private static func filterMatches(_ url: URL, bundleID: String, executable: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        let plist = try readPlist(url)
        guard let filter = plist["Filter"] as? [String: Any] else { throw LoadSideError("injection.filter", "Invalid Substrate filter: \(url.lastPathComponent)") }
        guard Set(filter.keys).isSubset(of: ["Bundles", "Executables", "Mode"]),
              filter["Mode"] == nil || filter["Mode"] as? String == "Any" else {
            throw LoadSideError("injection.filterUnsupported", "\(url.lastPathComponent) uses a Substrate filter that cannot be evaluated safely before launch.", recovery: "Provide a dylib deliberately built to load in this application without runtime filter evaluation.")
        }
        var matches: [Bool] = []
        for (key, expected) in [("Bundles", bundleID), ("Executables", executable)] where filter[key] != nil {
            guard let values = filter[key] as? [String] else { throw LoadSideError("injection.filter", "Invalid \(key) array in \(url.lastPathComponent).") }
            matches.append(values.contains(expected))
        }
        // Substrate's legacy default requires every present filter type to match. Mode=Any uses OR.
        guard !matches.isEmpty else { return false }
        return filter["Mode"] as? String == "Any" ? matches.contains(true) : matches.allSatisfy { $0 }
    }
    private static func validateArchitectures(_ info: MachOInfo, host: MachOInfo, name: String) throws {
        for slice in info.slices {
            guard slice.cpuType == 12 || slice.cpuType == 0x0100000c, slice.platform == nil || slice.platform == 2 else { throw LoadSideError("injection.platform", "\(name) contains a non-iOS-device architecture or platform.") }
        }
        for required in host.slices {
            guard info.slices.contains(where: { candidate in
                candidate.cpuType == required.cpuType && ((candidate.cpuSubtype & 0x00ffffff) == (required.cpuSubtype & 0x00ffffff) || (candidate.cpuType == 0x0100000c && candidate.cpuSubtype & 0x00ffffff == 0))
            }) else { throw LoadSideError("injection.architecture", "\(name) lacks a compatible \(required.architecture) slice.") }
        }
    }
    private static func isSystemDependency(_ path: String) -> Bool {
        guard !path.split(separator: "/").contains("..") else { return false }
        if path.hasPrefix("/System/Library/Frameworks/") || path.hasPrefix("/System/Library/PrivateFrameworks/") { return true }
        if path.hasPrefix("/usr/lib/swift/libswift"), path.hasSuffix(".dylib") { return true }
        return path.hasPrefix("/usr/lib/") && systemLibraries.contains(String(path.dropFirst(9)))
    }
    private static func allowsNameResolution(_ path: String) -> Bool {
        !path.split(separator: "/").contains("..") && ["@rpath/", "@loader_path/", "@executable_path/", "/usr/lib/", "/Library/Frameworks/", "/Library/MobileSubstrate/", "/var/jb/usr/lib/", "/var/jb/Library/Frameworks/"].contains(where: path.hasPrefix)
    }
    private static func existingDependency(_ path: String, candidate: Candidate, info: MachOInfo, host: MachOInfo, app: URL) throws -> URL? {
        let loader = app.appendingPathComponent("Frameworks/" + candidate.relativePath).deletingLastPathComponent()
        func expand(_ value: String, loaderRoot: URL) -> URL? {
            if value.hasPrefix("@executable_path/") { return app.appendingPathComponent(String(value.dropFirst(17))).standardizedFileURL }
            if value.hasPrefix("@loader_path/") { return loaderRoot.appendingPathComponent(String(value.dropFirst(13))).standardizedFileURL }
            return nil
        }
        var locations: [URL] = []
        if let direct = expand(path, loaderRoot: loader) { locations.append(direct) }
        if path.hasPrefix("@rpath/") {
            for rpath in Set(info.slices.flatMap(\.rpaths)) {
                if let root = expand(rpath + "/", loaderRoot: loader) { locations.append(root.appendingPathComponent(String(path.dropFirst(7))).standardizedFileURL) }
            }
            for rpath in Set(host.slices.flatMap(\.rpaths)) {
                if let root = expand(rpath + "/", loaderRoot: app) { locations.append(root.appendingPathComponent(String(path.dropFirst(7))).standardizedFileURL) }
            }
        }
        for location in locations where location.path.hasPrefix(app.standardizedFileURL.path + "/") {
            if FileManager.default.fileExists(atPath: location.path), location.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path + "/"), MachO.isMachO(location) { return location }
        }
        return nil
    }
}
