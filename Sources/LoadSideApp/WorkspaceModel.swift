import AppKit
import Foundation
import LoadSideCore
import SwiftUI
import UniformTypeIdentifiers

enum AppSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace", library = "Local Library", signingProfiles = "Signing Profiles", activity = "Activity", guide = "Help"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .workspace: "signature"
        case .library: "network"
        case .signingProfiles: "person.crop.rectangle.stack"
        case .activity: "clock.arrow.circlepath"
        case .guide: "questionmark.circle"
        }
    }
}

enum JobMode: String, Codable, CaseIterable {
    case sign, injectOnly
    var title: String { self == .sign ? "Sign & export" : "Inject only" }
}

enum JobStatus: String, Codable {
    case running, completed, failed, cancelled, interrupted
    var title: String { rawValue.capitalized }
}

struct JobRecord: Identifiable, Codable {
    var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var sourceName: String
    var status: JobStatus
    var output: URL
    var result: SigningResult?
    var events: [SigningEvent]
    var failure: String?
    var recovery: String?
    var errorCode: String?
    var entitlementPolicy: EntitlementPolicy
    var profileCount: Int
    var injectionNames: [String]
    var removeExtensions: Bool?
    var bundleIdentifierPolicy: BundleIdentifierPolicy?
    var savedSigningProfileID: UUID?
    var extensionProfilePolicy: ExtensionProfilePolicy?
    var jobMode: JobMode?
    var injectionResult: InjectionExportResult?
}

enum ProfileInspection: Sendable {
    case inspecting
    case valid(ProvisioningProfile)
    case invalid(message: String, recovery: String)
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var section: AppSection = .workspace
    @Published var jobMode: JobMode = .sign
    let localLibrary = LocalLibraryModel()
    @Published var ipa: URL? { didSet { refreshIPAInspection() } }
    @Published var certificate: URL? { didSet { if !applyingSavedSelection { invalidateSavedSelection() } } }
    @Published var password = ""
    @Published var profiles: [URL] = [] { didSet { refreshProfiles(); if !applyingSavedSelection { invalidateSavedSelection() } } }
    @Published private(set) var profileInspections: [URL: ProfileInspection] = [:]
    @Published var injections: [URL] = []
    @Published var bundleIdentifier = "" { didSet { refreshIdentifierSuggestion() } }
    @Published var identifierPolicy: BundleIdentifierPolicy = .preserve { didSet { refreshIdentifierSuggestion() } }
    @Published private(set) var ipaInspection: IPAInspection?
    @Published private(set) var isInspectingIPA = false
    @Published private(set) var ipaInspectionError: String?
    @Published private(set) var ipaInspectionRecovery: String?
    @Published private(set) var identifierSuggestion: BundleIdentifierSuggestion?
    @Published private(set) var identifierSuggestionError: String?
    @Published private(set) var identifierSuggestionRecovery: String?
    @Published private(set) var unmatchedExtensionIdentifiers: [String] = []
    @Published private(set) var unmatchedNestedAppIdentifiers: [String] = []
    @Published private(set) var savedSigningProfiles: [SavedSigningProfile] = []
    @Published private(set) var selectedSigningProfileID: UUID?
    @Published private(set) var isManagingSigningProfiles = false
    @Published var savedProfileNotice: String?
    @Published var displayName = ""
    @Published var policy: EntitlementPolicy = .strict
    @Published var removeExtensions = false { didSet { refreshIdentifierSuggestion() } }
    @Published var extensionProfilePolicy: ExtensionProfilePolicy = .reuseMain
    @Published var history: [JobRecord] = []
    @Published var activeJobID: UUID?
    @Published var selectedJobID: UUID?
    @Published var isRunning = false
    @Published var isCancelling = false
    @Published var notice: String?
    @Published var storageNotice: String?
    @Published var showAdvanced = false
    private var task: Task<Void, Never>?
    private var inspectionTokens: [URL: UUID] = [:]
    private var ipaInspectionToken = UUID()
    private var ipaInspectionTask: Task<Void, Never>?
    private var savedSelectionToken = UUID()
    private var applyingSavedSelection = false
    private let savedProfileStore = SavedSigningProfileStore()
    private let historyURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        historyURL = support.appendingPathComponent("LoadSide", isDirectory: true).appendingPathComponent("history.json")
        loadHistory()
        Task { [weak self] in await self?.loadSavedSigningProfiles(restoreSelection: true) }
    }

    var profilesReady: Bool {
        !profiles.isEmpty && profiles.allSatisfy { url in
            if case .valid(let profile) = profileInspections[url] { return profile.distribution != "App Store" }
            return false
        }
    }
    var canSign: Bool {
        guard ipa != nil, !isRunning, !isManagingSigningProfiles, !isInspectingIPA, ipaInspection != nil else { return false }
        if jobMode == .injectOnly { return !injections.isEmpty }
        return certificate != nil && profilesReady && identifierSuggestion != nil && unmatchedNestedAppIdentifiers.isEmpty && (removeExtensions || blockingExtensionIdentifiers.isEmpty)
    }
    var compatibilityExtensionIdentifiers: [String] {
        guard extensionProfilePolicy == .reuseMain, let plan = identifierSuggestion else { return [] }
        let mainProfiles = profiles.compactMap { url -> ProvisioningProfile? in
            if case .valid(let profile) = profileInspections[url], profile.bundleIdentifierPattern == plan.profileBundleIdentifier { return profile }
            return nil
        }
        guard Set(mainProfiles.map(\.uuid)).count == 1, let mainProfile = mainProfiles.first else { return [] }
        return unmatchedExtensionIdentifiers.filter { mainProfile.canReuseIdentity(forExtension: $0, mainBundleIdentifier: plan.effectiveIdentifier) }
    }
    var blockingExtensionIdentifiers: [String] {
        unmatchedExtensionIdentifiers.filter { !compatibilityExtensionIdentifiers.contains($0) }
    }
    var canSaveSigningProfile: Bool { certificate != nil && profilesReady && !isRunning && !isManagingSigningProfiles }
    var profileAppIDPatterns: [String] {
        Array(Set(profiles.compactMap { url -> String? in
            if case .valid(let profile) = profileInspections[url] { return profile.bundleIdentifierPattern }
            return nil
        })).sorted()
    }
    var selectedSigningProfile: SavedSigningProfile? { savedSigningProfiles.first { $0.id == selectedSigningProfileID } }
    var signingPlanNote: String { "The signing engine also checks certificate membership and entitlements before signing." }
    var currentJob: JobRecord? { history.first { $0.id == activeJobID } }
    var selectedJob: JobRecord? { history.first { $0.id == selectedJobID } ?? history.first }
    var missingInputs: String {
        if ipa == nil { return "Add an IPA to begin" }
        if isInspectingIPA { return "Inspecting the application…" }
        if ipaInspectionError != nil { return "Resolve the application inspection error" }
        if jobMode == .injectOnly { return injections.isEmpty ? "Add a DEB, dylib, or framework" : "Ready to inject and export unsigned" }
        if certificate == nil { return "Add a signing certificate" }
        if profiles.isEmpty { return "Add a provisioning profile" }
        if profiles.contains(where: { if case .inspecting = profileInspections[$0] { return true }; return false }) {
            return "Checking provisioning profiles…"
        }
        if !profilesReady { return "Resolve provisioning profile errors" }
        if isManagingSigningProfiles { return "Loading signing files…" }
        if identifierSuggestionError != nil { return "Resolve the bundle identifier plan" }
        if !unmatchedNestedAppIdentifiers.isEmpty { return "Add matching profiles for nested apps" }
        if !removeExtensions && !blockingExtensionIdentifiers.isEmpty { return "Add matching profiles to keep app extensions" }
        if !removeExtensions && !compatibilityExtensionIdentifiers.isEmpty { return "Ready with experimental extension compatibility" }
        if identifierSuggestion?.usesProfileIdentity == true { return "Ready with profile signing identity" }
        return "Ready to sign and export"
    }

    func chooseIPA() { selectFiles(kind: .ipa) }
    func chooseCertificate() { selectFiles(kind: .certificate) }
    func chooseProfiles() { selectFiles(kind: .profile) }
    func chooseInjections() { selectFiles(kind: .injection) }

    /// The two checkbox controls share one nonoptional policy, so exactly one
    /// remains selected. Clicking the selected choice cannot clear the policy.
    func selectExtensionProfilePolicy(_ policy: ExtensionProfilePolicy, isSelected: Bool) {
        guard isSelected, !isRunning else { return }
        extensionProfilePolicy = policy
    }

    func inspectProfile(_ url: URL) {
        let token = UUID()
        inspectionTokens[url] = token
        profileInspections[url] = .inspecting
        Task { [weak self] in
            let inspection = await Task.detached(priority: .userInitiated) { () -> ProfileInspection in
                do {
                    return .valid(try ProvisioningProfile.inspect(url))
                } catch {
                    return .invalid(message: error.localizedDescription,
                                    recovery: (error as? LocalizedError)?.recoverySuggestion ?? "Choose a current, unmodified Apple-issued provisioning profile.")
                }
            }.value
            guard let self, profiles.contains(url), inspectionTokens[url] == token else { return }
            profileInspections[url] = inspection
            refreshIdentifierSuggestion()
        }
    }

    private func refreshProfiles() {
        profileInspections = profileInspections.filter { profiles.contains($0.key) }
        inspectionTokens = inspectionTokens.filter { profiles.contains($0.key) }
        for url in profiles where profileInspections[url] == nil { inspectProfile(url) }
        refreshIdentifierSuggestion()
    }

    private func refreshIPAInspection() {
        ipaInspectionTask?.cancel()
        let token = UUID(); ipaInspectionToken = token
        ipaInspection = nil; ipaInspectionError = nil; ipaInspectionRecovery = nil
        refreshIdentifierSuggestion()
        guard let source = ipa else { isInspectingIPA = false; return }
        isInspectingIPA = true
        ipaInspectionTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try SigningPreflight.inspectIPA(source) }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, ipaInspectionToken == token, ipa == source else { return }
                ipaInspection = value; isInspectingIPA = false
                refreshIdentifierSuggestion()
            } catch {
                guard let self, ipaInspectionToken == token, ipa == source else { return }
                isInspectingIPA = false
                if !(error is CancellationError) {
                    ipaInspectionError = error.localizedDescription
                    ipaInspectionRecovery = (error as? LocalizedError)?.recoverySuggestion
                }
                refreshIdentifierSuggestion()
            }
        }
    }

    private func refreshIdentifierSuggestion() {
        identifierSuggestion = nil; identifierSuggestionError = nil; identifierSuggestionRecovery = nil
        unmatchedExtensionIdentifiers = []
        unmatchedNestedAppIdentifiers = []
        guard let inspection = ipaInspection else { return }
        let checked = profiles.compactMap { url -> ProvisioningProfile? in
            if case .valid(let profile) = profileInspections[url] { return profile }; return nil
        }
        guard !checked.isEmpty, checked.count == profiles.count else { return }
        do {
            let nested = (removeExtensions ? [] : inspection.extensionBundleIdentifiers) + inspection.nestedAppBundleIdentifiers
            let suggestion = try SigningPreflight.suggestBundleIdentifier(original: inspection.bundleIdentifier, profiles: checked, policy: identifierPolicy, override: nonempty(bundleIdentifier), nestedOriginalIdentifiers: nested)
            identifierSuggestion = suggestion
            for original in inspection.extensionBundleIdentifiers {
                let effective = suggestion.identifier(forOriginalBundleIdentifier: original)
                let matches = checked.contains { $0.matches(bundleIdentifier: effective) }
                if !matches { unmatchedExtensionIdentifiers.append(effective) }
            }
            unmatchedNestedAppIdentifiers = inspection.nestedAppBundleIdentifiers.compactMap { original in
                let effective = suggestion.identifier(forOriginalBundleIdentifier: original)
                return checked.contains { $0.matches(bundleIdentifier: effective) } ? nil : effective
            }
        } catch {
            identifierSuggestionError = error.localizedDescription
            identifierSuggestionRecovery = (error as? LocalizedError)?.recoverySuggestion
        }
    }

    func removeUnmatchedExtensions() {
        guard !isRunning, !isManagingSigningProfiles, !unmatchedExtensionIdentifiers.isEmpty else { return }
        removeExtensions = true
    }

    func loadSavedSigningProfiles(restoreSelection: Bool = false) async {
        do {
            let library = try await savedProfileStore.library()
            savedSigningProfiles = library.profiles
            if !library.issues.isEmpty { savedProfileNotice = library.issues.joined(separator: "\n") }
            if restoreSelection, certificate == nil, profiles.isEmpty, let selected = library.lastSelectedID {
                await selectSigningProfile(selected)
            }
        } catch { savedProfileNotice = "Saved signing profiles could not be loaded: \(error.localizedDescription)" }
    }

    func saveSigningProfile(name: String, rememberPassword: Bool = false) async {
        guard canSaveSigningProfile, let certificate else { return }
        isManagingSigningProfiles = true; savedProfileNotice = nil
        let token = UUID(); savedSelectionToken = token
        let sourceProfiles = profiles, suppliedPassword = password
        defer { isManagingSigningProfiles = false }
        do {
            let saved = try await savedProfileStore.save(name: name, certificate: certificate, password: suppliedPassword, profiles: sourceProfiles, rememberPassword: rememberPassword)
            await loadSavedSigningProfiles()
            guard savedSelectionToken == token else { return }
            let selection = try await savedProfileStore.select(saved.id, loadPassword: false)
            if let selection { applySavedSelection(selection) }
            password = suppliedPassword
            savedProfileNotice = selection?.passwordNotice ?? (rememberPassword ? "Signing files saved privately. The password is remembered in this Mac’s Keychain." : "Signing files saved privately. The current password remains only in this session and was not saved.")
        } catch { savedProfileNotice = redact(error.localizedDescription, secret: suppliedPassword) }
    }

    func selectSigningProfile(_ id: UUID?) async {
        guard !isRunning, !isManagingSigningProfiles else { return }
        isManagingSigningProfiles = true; savedProfileNotice = nil
        let token = UUID(); savedSelectionToken = token
        defer { isManagingSigningProfiles = false }
        do {
            let selection = try await savedProfileStore.select(id, loadPassword: false)
            guard savedSelectionToken == token else { return }
            if let selection { applySavedSelection(selection) }
            else { selectedSigningProfileID = nil }
        } catch {
            guard savedSelectionToken == token else { return }
            savedProfileNotice = error.localizedDescription
        }
    }

    func renameSigningProfile(_ id: UUID, name: String) async {
        guard !isRunning, !isManagingSigningProfiles else { return }
        isManagingSigningProfiles = true; defer { isManagingSigningProfiles = false }
        do { try await savedProfileStore.rename(id, name: name); await loadSavedSigningProfiles() }
        catch { savedProfileNotice = error.localizedDescription }
    }

    func deleteSigningProfile(_ id: UUID) async {
        guard !isRunning, !isManagingSigningProfiles else { return }
        isManagingSigningProfiles = true; defer { isManagingSigningProfiles = false }
        do {
            try await savedProfileStore.delete(id)
            if selectedSigningProfileID == id {
                applyingSavedSelection = true
                certificate = nil; profiles = []; password = ""; selectedSigningProfileID = nil
                applyingSavedSelection = false
            }
            await loadSavedSigningProfiles()
        } catch { savedProfileNotice = error.localizedDescription }
    }

    private func applySavedSelection(_ selection: SavedSigningProfileSelection) {
        applyingSavedSelection = true
        certificate = selection.certificate; profiles = selection.provisioningProfiles
        password = selection.password ?? ""; selectedSigningProfileID = selection.profile.id
        applyingSavedSelection = false
        // Force fresh CMS/date checks when reselecting the same saved files.
        for profile in profiles { inspectProfile(profile) }
        savedProfileNotice = selection.passwordNotice
    }

    private func invalidateSavedSelection() {
        guard selectedSigningProfileID != nil else { return }
        selectedSigningProfileID = nil; savedSelectionToken = UUID()
        Task { [weak self] in
            do { _ = try await self?.savedProfileStore.select(nil) }
            catch { self?.savedProfileNotice = "The last selected profile could not be updated: \(error.localizedDescription)" }
        }
    }

    enum InputKind {
        case ipa, certificate, profile, injection
        var extensions: [String] {
            switch self {
            case .ipa: ["ipa"]
            case .certificate: ["p12", "pfx"]
            case .profile: ["mobileprovision"]
            case .injection: ["deb", "dylib", "framework"]
            }
        }
        var title: String {
            switch self {
            case .ipa: "Choose a decrypted IPA"
            case .certificate: "Choose a signing certificate"
            case .profile: "Choose provisioning profiles"
            case .injection: "Choose libraries or DEB packages"
            }
        }
    }

    private func selectFiles(kind: InputKind) {
        guard !isRunning, !isManagingSigningProfiles else { return }
        let panel = NSOpenPanel()
        panel.title = kind.title
        panel.prompt = "Add"
        panel.allowsMultipleSelection = kind == .profile || kind == .injection
        panel.canChooseDirectories = kind == .injection
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = kind.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.accept(panel.urls, kind: kind)
        }
    }

    @discardableResult
    func accept(_ urls: [URL], kind: InputKind? = nil) -> Bool {
        guard !isRunning, !isManagingSigningProfiles else { return false }
        var accepted = 0
        var rejected: [String] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path),
                  kind == nil || kind!.extensions.contains(ext) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            switch ext {
            case "ipa": ipa = url
            case "p12", "pfx": certificate = url
            case "mobileprovision":
                if !profiles.contains(url) { profiles.append(url) }
            case "deb", "dylib", "framework":
                if !injections.contains(url) { injections.append(url) }
            default:
                rejected.append(url.lastPathComponent)
                continue
            }
            accepted += 1
        }
        if !rejected.isEmpty {
            notice = "Could not add \(rejected.joined(separator: ", ")). Choose an IPA, P12, provisioning profile, DEB, dylib, or framework."
        }
        if accepted > 0 { section = .workspace }
        return accepted > 0
    }

    func beginSigning() {
        guard canSign else { return }
        if jobMode == .sign, password.isEmpty, let selected = selectedSigningProfile, selected.remembersPassword {
            isManagingSigningProfiles = true
            let selectionID = selected.id, token = UUID()
            savedSelectionToken = token
            Task { [weak self] in
                guard let self else { return }
                do {
                    let selection = try await savedProfileStore.select(selectionID)
                    guard savedSelectionToken == token, selectedSigningProfileID == selectionID else { isManagingSigningProfiles = false; return }
                    guard let remembered = selection?.password else {
                        savedProfileNotice = selection?.passwordNotice ?? "The remembered password is unavailable. Enter it again before signing."
                        notice = savedProfileNotice
                        isManagingSigningProfiles = false
                        return
                    }
                    // An explicitly remembered empty password is valid and must not trigger recursion.
                    password = remembered
                    isManagingSigningProfiles = false
                    presentExportPanel()
                } catch {
                    isManagingSigningProfiles = false
                    savedProfileNotice = error.localizedDescription
                    notice = "The saved signing profile could not be loaded: \(error.localizedDescription)"
                }
            }
            return
        }
        presentExportPanel()
    }

    private func presentExportPanel() {
        guard canSign, let ipa else { return }
        let panel = NSSavePanel()
        panel.title = jobMode == .sign ? "Export signed IPA" : "Export unsigned injected IPA"
        panel.prompt = jobMode == .sign ? "Sign & Export" : "Inject & Export"
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        panel.nameFieldStringValue = ipa.deletingPathExtension().lastPathComponent + (jobMode == .sign ? "-signed.ipa" : "-injected-unsigned.ipa")
        panel.canCreateDirectories = true
        panel.message = jobMode == .sign ? "The export is written only after all signing and verification steps succeed." : "No certificate is needed. This export must be signed before ordinary iOS installation."
        panel.begin { [weak self] response in
            guard response == .OK, let output = panel.url else { return }
            self?.run(output: output)
        }
    }

    private func run(output: URL) {
        guard canSign, let ipa else { return }
        if output.standardizedFileURL == ipa.standardizedFileURL {
            notice = "Choose a different export name. Your original IPA must be preserved."
            return
        }
        if FileManager.default.fileExists(atPath: output.path) {
            notice = "An export already exists at this destination. Choose a new name to preserve the existing file."
            return
        }
        let mode = jobMode
        let request = mode == .sign ? certificate.map { certificate in SigningRequest(
            ipa: ipa, certificate: certificate, password: password, profiles: profiles,
            injections: injections, output: output,
            bundleIdentifier: nonempty(bundleIdentifier), displayName: nonempty(displayName),
            removeExtensions: removeExtensions, entitlementPolicy: policy, bundleIdentifierPolicy: identifierPolicy,
            extensionProfilePolicy: removeExtensions ? .matching : extensionProfilePolicy
        ) } : nil
        let injectionRequest = InjectionRequest(ipa: ipa, injections: injections, output: output,
                                               displayName: nonempty(displayName), removeExtensions: removeExtensions)
        let jobID = UUID()
        let record = JobRecord(
            id: jobID, startedAt: Date(), sourceName: ipa.lastPathComponent,
            status: .running, output: output, events: [], entitlementPolicy: policy,
            profileCount: mode == .sign ? profiles.count : 0, injectionNames: injections.map(\.lastPathComponent),
            removeExtensions: removeExtensions, bundleIdentifierPolicy: mode == .sign ? identifierPolicy : nil,
            savedSigningProfileID: mode == .sign ? selectedSigningProfileID : nil,
            extensionProfilePolicy: request?.extensionProfilePolicy, jobMode: mode
        )
        history.insert(record, at: 0)
        history = Array(history.prefix(50))
        activeJobID = jobID
        selectedJobID = jobID
        isRunning = true
        isCancelling = false
        section = .workspace
        persistHistory()
        let secret = mode == .sign ? password : ""
        password = ""
        task = Task { [weak self] in
            do {
                let onEvent: @Sendable (SigningEvent) -> Void = { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.receive(event, for: jobID, secret: secret)
                    }
                }
                if let request {
                    let result = try await SigningEngine().run(request, onEvent: onEvent)
                    self?.finish(jobID, result: result)
                } else {
                    let result = try await InjectionEngine().run(injectionRequest, onEvent: onEvent)
                    self?.finish(jobID, injectionResult: result)
                }
            } catch {
                self?.finish(jobID, error: error, secret: secret)
            }
        }
    }

    private func receive(_ event: SigningEvent, for id: UUID, secret: String) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        let safeMessage = redact(event.message, secret: secret)
        let safeEvent = SigningEvent(stage: event.stage, fraction: event.fraction, message: safeMessage, level: event.level)
        history[index].events.append(safeEvent)
        if history[index].events.count > 1_000 { history[index].events.removeFirst() }
        persistHistory()
    }

    private func finish(_ id: UUID, result: SigningResult) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].status = .completed
        history[index].result = result
        history[index].finishedAt = Date()
        didFinish()
        Task { await localLibrary.add(result) }
    }

    private func finish(_ id: UUID, injectionResult: InjectionExportResult) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].status = .completed
        history[index].injectionResult = injectionResult
        history[index].finishedAt = Date()
        didFinish()
    }

    private func finish(_ id: UUID, error: Error, secret: String) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        let cancelled = error is CancellationError || (error as? LoadSideError)?.code == "cancelled"
        history[index].status = cancelled ? .cancelled : .failed
        history[index].failure = cancelled ? "The export was cancelled." : redact(error.localizedDescription, secret: secret)
        history[index].recovery = cancelled
            ? "Your input files are unchanged. Start a new export when ready."
            : (error as? LocalizedError)?.recoverySuggestion.map { redact($0, secret: secret) }
                ?? "Review the diagnostics, update your inputs, and try again."
        history[index].errorCode = (error as? LoadSideError)?.code
        history[index].finishedAt = Date()
        didFinish()
    }

    private func didFinish() {
        isRunning = false
        isCancelling = false
        task = nil
        persistHistory()
    }

    func cancel() {
        guard isRunning else { return }
        isCancelling = true
        task?.cancel()
    }

    func reset() {
        guard !isRunning, !isManagingSigningProfiles else { return }
        ipa = nil; password = ""
        jobMode = .sign
        if selectedSigningProfileID == nil { certificate = nil; profiles = [] }
        injections = []
        bundleIdentifier = ""; identifierPolicy = .preserve; displayName = ""; policy = .strict; removeExtensions = false; extensionProfilePolicy = .reuseMain
        showAdvanced = false
        activeJobID = nil
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func exportDiagnostics(_ job: JobRecord) {
        let panel = NSSavePanel()
        panel.title = "Export diagnostics"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LoadSide-\(job.id.uuidString.prefix(8))-diagnostics.json"
        panel.message = "Includes event messages, source file names, certificate identity, and the export path. Review before sharing. Passwords are never included."
        panel.begin { [weak self] response in
            guard response == .OK, let output = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(job).write(to: output, options: .atomic)
                self?.reveal(output)
            } catch {
                self?.notice = "Could not save diagnostics: \(error.localizedDescription)"
            }
        }
    }

    func clearHistory() {
        history.removeAll { $0.id != activeJobID || !isRunning }
        if !isRunning { activeJobID = nil; selectedJobID = nil }
        persistHistory()
    }

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            history = try JSONDecoder().decode([JobRecord].self, from: Data(contentsOf: historyURL))
            for index in history.indices where history[index].status == .running {
                history[index].status = .interrupted
                history[index].failure = "LoadSide closed before this job finished."
                history[index].recovery = "Start a new signing session. Any existing export should be treated as unverified."
            }
            persistHistory()
        } catch {
            storageNotice = "Previous activity could not be loaded. Your signing files are unaffected."
        }
    }

    private func persistHistory() {
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        } catch {
            storageNotice = "Activity could not be saved: \(error.localizedDescription)"
        }
    }

    private func nonempty(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func redact(_ text: String, secret: String) -> String {
        secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: "[redacted]")
    }
}
