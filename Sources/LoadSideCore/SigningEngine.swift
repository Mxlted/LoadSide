import Foundation

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
                // Diagnostics can contain untrusted filenames. Only parsed load
                // commands establish that the executable has no signature to read.
                guard try !MachO.inspect(bundle.executable).hasCodeSignature else { throw LoadSideError("entitlements.read", "Could not inspect the original entitlements of \(bundle.identifier): \(result.diagnostic)") }
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
                                                                   policy: request.bundleIdentifierPolicy, override: request.bundleIdentifier,
                                                                   nestedOriginalIdentifiers: bundles.filter { $0.requiresProfile && $0.url != mainApp }.map(\.identifier))
        if identifierPlan.changesIdentifier {
            try BundleInventory.rewriteIdentifiers(in: bundles, original: main.identifier, replacement: identifierPlan.effectiveIdentifier)
            let warning = "Changed bundle identifier \(main.identifier) → \(identifierPlan.effectiveIdentifier) to match the selected profile. Prefix-related nested identifiers follow this change; existing app data and runtime bundle-identifier checks are not migrated."
            warnings.append(warning)
            emit(.credentials, 0.27, warning, .warning)
        } else {
            emit(.credentials, 0.27, "Keeping the original bundle identifier: \(main.identifier).")
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
        var entitlementWarnings: [String] = []
        var teams = Set<String>()
        let mainProfile = try ProvisioningProfile.select(from: profiles, bundleIdentifier: identifierPlan.profileBundleIdentifier, certificate: identity.certificate)
        for (index, bundle) in bundles.filter(\.requiresProfile).enumerated() {
            try Task.checkCancellation()
            let selection: BundleProfileSelection
            do {
                if bundle.url == mainApp {
                    selection = BundleProfileSelection(profile: mainProfile, usesProfileIdentity: identifierPlan.usesProfileIdentity)
                } else {
                    selection = try ProvisioningProfile.selectForBundle(from: profiles, bundleIdentifier: bundle.identifier,
                        certificate: identity.certificate, mainProfile: mainProfile, mainBundleIdentifier: updatedMain.identifier,
                        isExtension: bundle.url.pathExtension.lowercased() == "appex", policy: request.extensionProfilePolicy)
                }
            } catch let error as LoadSideError where error.code == "profile.noMatch" {
                if bundle.url.pathExtension.lowercased() == "appex" {
                    let policyRecovery = request.extensionProfilePolicy == .matching
                        ? "Experimental main-profile reuse is available for child extensions of an exact main-app profile; installation and extension behavior remain unverified."
                        : "Experimental reuse applies only to child extensions of the main app with an exact main-app profile; it cannot replace an incompatible supplied extension profile."
                    throw LoadSideError("profile.extensionNoMatch", "The retained extension \(bundle.identifier) has no usable profile for the selected certificate. \(error.message)", recovery: "Add an Apple-issued profile authorizing \(bundle.identifier) and containing the same signing certificate. A matching wildcard profile may cover several bundles. \(policyRecovery) Remove Extensions is an optional fallback that disables extension functionality.")
                }
                if bundle.url != mainApp {
                    throw LoadSideError("profile.nestedAppNoMatch", "Nested app \(bundle.identifier) needs its own matching profile for the selected certificate.", recovery: "Add a matching profile for this nested app. Remove Extensions does not remove nested apps such as Watch apps.")
                }
                throw error
            }
            let profile = selection.profile
            if selection.usesProfileIdentity {
                let warning = bundle.url == mainApp
                    ? "Original-ID compatibility: retained bundle identifier \(bundle.identifier) with signing application-identifier \(profile.applicationIdentifier) from profile “\(profile.name)”. These identifiers differ. Keychain access, file importing, app groups, and other features may behave differently. Device installation and runtime behavior are unverified."
                    : "Extension compatibility: retained \(bundle.identifier) with signing application-identifier \(profile.applicationIdentifier) from main profile “\(profile.name)”. These identifiers differ. The app and extension share a signing identity and may share keychain access; file importing, app groups, and other extension features may fail. Device installation and extension behavior are unverified."
                warnings.append(warning)
                emit(.entitlements, 0.30, warning, .warning)
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
            let resolved = try EntitlementResolver.resolve(requested: originalEntitlements[bundle.url] ?? [:], profile: profile, bundleIdentifier: bundle.identifier, policy: request.entitlementPolicy, useProfileIdentity: selection.usesProfileIdentity) { warning in
                entitlementWarnings.append(warning)
                emit(.entitlements, 0.30 + 0.08 * Double(index) / Double(bundles.count), warning, .warning)
            }
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
        warnings += entitlementWarnings
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
        let hash = try IPAExport.write(from: extracted, to: request.output)
        emit(.completed, 1, "Export complete. Every code object passed local signature verification.")
        return SigningResult(output: request.output, bundleIdentifier: updatedMain.identifier,
                             displayName: updatedMain.info["CFBundleDisplayName"] as? String ?? updatedMain.info["CFBundleName"] as? String ?? updatedMain.url.deletingPathExtension().lastPathComponent,
                             certificateName: identity.name, teamIdentifier: team, signedCodeCount: targets.count,
                             injectedLibraryCount: injectedCount, warnings: warnings, sha256: hash,
                             bundleVersion: updatedMain.info["CFBundleVersion"] as? String)
    }

    static func validate(_ request: SigningRequest) throws {
        guard !request.removeExtensions || request.extensionProfilePolicy == .matching else {
            throw LoadSideError("request.extensionPolicy", "Choose extension removal or experimental profile reuse, not both.")
        }
        guard !request.profiles.isEmpty else { throw LoadSideError("request.profiles", "Add at least one provisioning profile.") }
        try IPAExport.validatePaths(ipa: request.ipa, output: request.output)
        if let identifier = request.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty {
            try SigningPreflight.validateIdentifier(identifier)
        }
        try IPAExport.validateInputs([request.ipa, request.certificate] + request.profiles + request.injections, output: request.output)
    }

}
