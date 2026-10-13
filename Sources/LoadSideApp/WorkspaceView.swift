import SwiftUI
import LoadSideCore

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var isDropTarget = false
    @State private var showSaveProfile = false
    @State private var showExtensionList = false
    @State private var showCompatibilityDetails = false
    @State private var showExtensionOptions = false
    @State private var showEntitlements = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    workspaceHeading
                    applicationInput
                    if let error = model.ipaInspectionError {
                        InlineNotice(message: error + " " + (model.ipaInspectionRecovery ?? ""), color: Palette.error)
                    }
                }
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 16)

                if geometry.size.width >= 820 {
                    HStack(alignment: .top, spacing: 18) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if model.jobMode == .sign { credentials } else { injections }
                            }
                            .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if let job = model.currentJob { currentJob(job) }
                                if model.jobMode == .sign { signingPlan } else { injectionPlan }
                                if model.jobMode == .sign { injections }
                                if let notice = model.storageNotice { InlineNotice(message: notice) }
                            }
                            .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .padding(.horizontal, 22)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if model.jobMode == .sign { credentials }
                            injections
                            if model.jobMode == .sign { signingPlan } else { injectionPlan }
                            if let job = model.currentJob { currentJob(job) }
                            if let notice = model.storageNotice { InlineNotice(message: notice) }
                        }
                        .padding(.horizontal, 22).padding(.bottom, 16)
                    }
                }
                exportBar.padding(.horizontal, 22).padding(.bottom, 14).padding(.top, 8)
            }
        }
        .sheet(isPresented: $showSaveProfile) { SaveSigningProfileSheet(model: model) }
    }

    private var workspaceHeading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                PageHeading(title: "Prepare an app", detail: "Sign locally, or inject now and sign later.")
                Spacer(minLength: 12)
                workflowPicker.frame(width: 264)
            }
            VStack(alignment: .leading, spacing: 10) {
                PageHeading(title: "Prepare an app")
                workflowPicker
            }
        }
    }

    private var workflowPicker: some View {
        Picker("Workflow", selection: $model.jobMode) {
            Text("Sign & export").tag(JobMode.sign)
            Text("Inject only").tag(JobMode.injectOnly)
        }
        .pickerStyle(.segmented).labelsHidden()
        .disabled(model.isRunning || model.isManagingSigningProfiles)
        .help("Inject only prepares an unsigned IPA without a certificate. Signing is still required before installation.")
    }

    private var applicationInput: some View {
        HStack(spacing: 15) {
            SymbolTile(symbol: model.ipa == nil ? "square.and.arrow.down" : "app.fill", size: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.ipaInspection?.displayName ?? model.ipa?.deletingPathExtension().lastPathComponent ?? "Choose a decrypted IPA")
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let ipa = model.ipa {
                    Text(ipa.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(ipa.path)
                    if model.isInspectingIPA {
                        HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Inspecting application…") }.font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if let inspection = model.ipaInspection {
                        HStack(spacing: 7) {
                            Text(inspection.bundleIdentifier).lineLimit(1).truncationMode(.middle)
                            Text("·")
                            Text("\(inspection.extensionCount) extensions")
                        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    Text("Drop it here or choose a file. Your original stays unchanged.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(model.ipa == nil ? "Open IPA…" : "Change…", action: model.chooseIPA).controlSize(.large).disabled(model.isRunning || model.isManagingSigningProfiles)
                .help("Choose an IPA (⌘O)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDropTarget ? Palette.accent.opacity(0.1) : Palette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(isDropTarget ? Palette.accent : Palette.separator, style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1, dash: model.ipa == nil ? [6, 4] : [])))
        .dropDestination(for: URL.self) { urls, _ in model.accept(urls, kind: .ipa) } isTargeted: { isDropTarget = $0 }
        .overlay(alignment: .bottomLeading) {
            if model.ipaInspectionError != nil { Rectangle().fill(Palette.error).frame(width: 3).padding(.vertical, 12) }
        }
        .accessibilityElement(children: .contain)
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                SectionHeading(title: "Signing identity")
                Spacer()
                Button("Manage") { model.section = .signingProfiles }.buttonStyle(.link).font(.system(size: 11))
            }
            Panel(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Saved profile", selection: Binding<UUID?>(get: { model.selectedSigningProfileID }, set: { id in Task { await model.selectSigningProfile(id) } })) {
                        Text("Imported files").tag(nil as UUID?)
                        ForEach(model.savedSigningProfiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                    }.font(.system(size: 12)).disabled(model.isManagingSigningProfiles)
                    if model.isManagingSigningProfiles { ProgressView("Updating signing profile…").controlSize(.small).font(.system(size: 11)) }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Certificate").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            Button(model.certificate == nil ? "Import P12…" : "Replace…", action: model.chooseCertificate).controlSize(.small)
                        }
                        if let certificate = model.certificate {
                            FileRow(url: certificate, symbol: "key.horizontal") { model.certificate = nil; model.password = "" }
                        } else {
                            Text("Import your Apple certificate and private key.").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        SecureField("P12 password", text: $model.password).inputField().accessibilityLabel("Certificate password")
                        if model.selectedSigningProfile?.remembersPassword == true && model.password.isEmpty {
                            Label("Saved password will be requested from Keychain when you sign.", systemImage: "lock.shield")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Provisioning profiles").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Add…", action: model.chooseProfiles).controlSize(.small)
                        }
                        if model.profiles.isEmpty {
                            Text("Add a .mobileprovision for the app and its extensions.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.profiles, id: \.self) { url in profileRow(url) }
                    }
                    Divider()
                    HStack {
                        Image(systemName: "key.viewfinder").foregroundStyle(.tertiary)
                        Text("Save this identity for next time").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Save…") { showSaveProfile = true }.controlSize(.small)
                            .disabled(!model.canSaveSigningProfile)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in model.accept(urls.filter { ["p12", "pfx", "mobileprovision"].contains($0.pathExtension.lowercased()) }) }
            if let notice = model.savedProfileNotice { InlineNotice(message: notice, color: Palette.accent, symbol: "info.circle") }
        }.disabled(model.isRunning)
    }

    @ViewBuilder private func profileRow(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                Text(profileName(url)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                RemoveButton(label: "Remove \(url.lastPathComponent)") { model.profiles.removeAll { $0 == url } }
            }.help(url.path)
            switch model.profileInspections[url] {
            case .valid(let profile):
                Text(profile.applicationIdentifier).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("\(profile.distribution) · \(profile.deviceCount) devices · Expires \(profile.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if profile.distribution == "App Store" { InlineNotice(message: "App Store profiles cannot authorize a direct-install export. Choose an Ad Hoc, Development, or Enterprise profile.") }
            case .invalid(let message, let recovery):
                InlineNotice(message: message + " " + recovery, color: Palette.error)
                Button("Check again") { model.inspectProfile(url) }.buttonStyle(.link).font(.system(size: 11))
            case .inspecting, .none:
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Validating profile…").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }.padding(.vertical, 2)
    }

    private func profileName(_ url: URL) -> String {
        if case .valid(let profile) = model.profileInspections[url] { return profile.name }
        return url.lastPathComponent
    }

    private var signingPlan: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeading(title: "Signing options")
            Panel(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bundle identifier").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Picker("Bundle identifier policy", selection: $model.identifierPolicy) {
                            Text("Keep original").tag(BundleIdentifierPolicy.preserve)
                            Text("Automatic").tag(BundleIdentifierPolicy.automatic)
                        }.pickerStyle(.segmented).labelsHidden()
                        if let suggestion = model.identifierSuggestion {
                            Text(suggestion.effectiveIdentifier).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                            if suggestion.usesProfileIdentity {
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    Text("Profile signing ID:").foregroundStyle(.secondary)
                                    Text(suggestion.profileBundleIdentifier).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                }.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                                InlineNotice(message: "Keeps the app’s original bundle ID and uses your profile’s identity in the signature. This compatibility mode may affect keychain access and app services; device behavior is unverified.", color: Palette.warning, symbol: "exclamationmark.triangle")
                            } else if suggestion.changesIdentifier {
                                Text("Changed from \(suggestion.originalIdentifier)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                InlineNotice(message: suggestion.reason, color: Palette.accent, symbol: "arrow.triangle.2.circlepath")
                            } else {
                                Text(suggestion.reason).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text(model.identifierPolicy == .automatic ? "Uses an unambiguous profile ID only if the original ID is not authorized." : "Keeps the app’s original bundle ID. When needed, the signature uses your profile’s exact app identity.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let error = model.identifierSuggestionError {
                            InlineNotice(message: error, color: Palette.error)
                            if let recovery = model.identifierSuggestionRecovery { Text(recovery).font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        if model.identifierSuggestion != nil {
                            Text("Certificate authorization is verified when signing starts.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    Divider()
                    DisclosureGroup(isExpanded: $showExtensionOptions) {
                        extensionPlan.padding(.top, 10)
                    } label: {
                        optionSummary("Extensions", value: model.removeExtensions ? "Remove from export" : model.extensionProfilePolicy == .reuseMain ? "Reuse main · experimental" : "Matching profiles", warning: model.removeExtensions || model.extensionProfilePolicy == .reuseMain)
                    }
                    .font(.system(size: 12))
                    if !showExtensionOptions, !model.blockingExtensionIdentifiers.isEmpty, !model.removeExtensions {
                        InlineNotice(message: "\(model.blockingExtensionIdentifiers.count) extension(s) need profiles. Open Extensions to review.")
                    }
                    if !showExtensionOptions, !model.compatibilityExtensionIdentifiers.isEmpty, !model.removeExtensions {
                        Text("\(model.compatibilityExtensionIdentifiers.count) extension(s) will share the main signing identity. Device behavior is unverified.")
                            .font(.system(size: 11)).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
                    }
                    if !showExtensionOptions, !model.unmatchedNestedAppIdentifiers.isEmpty {
                        InlineNotice(message: "Nested apps need matching profiles. Open Extensions to review.")
                    }
                    Divider()
                    DisclosureGroup(isExpanded: $showEntitlements) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Entitlement policy", selection: $model.policy) {
                                Text("Strict").tag(EntitlementPolicy.strict)
                                Text("Compatible").tag(EntitlementPolicy.compatible)
                            }.pickerStyle(.segmented).labelsHidden()
                            Text(model.policy == .strict ? "Keeps authorized capabilities; stops when others cannot be preserved. Unapproved Apple-restricted entitlements are omitted and logged." : "Removes unsupported capabilities and records each change. Push notifications, app groups, or other features may stop working.")
                                .font(.system(size: 11)).foregroundStyle(model.policy == .strict ? Color.secondary : Palette.warning).fixedSize(horizontal: false, vertical: true)
                        }.padding(.top, 10)
                    } label: {
                        optionSummary("Entitlements", value: model.policy == .strict ? "Strict" : "Compatible · may remove features", warning: model.policy == .compatible)
                    }
                    .font(.system(size: 12))
                    Divider()
                    DisclosureGroup("App overrides", isExpanded: $model.showAdvanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Bundle ID (optional)", text: $model.bundleIdentifier).inputField().accessibilityLabel("Explicit bundle identifier override")
                            Text("An explicit ID overrides the selection above and must be authorized by a supplied profile.").font(.system(size: 11)).foregroundStyle(.secondary)
                            TextField("Display name (optional)", text: $model.displayName).inputField().accessibilityLabel("App display name override")
                        }.padding(.top, 8)
                    }.font(.system(size: 11, weight: .medium))
                }
            }
        }.disabled(model.isRunning)
    }

    private func optionSummary(_ title: String, value: String, warning: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title).fontWeight(.medium)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 11)).foregroundStyle(warning ? Palette.warning : Color.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var injectionPlan: some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionHeading(title: "Unsigned export")
            Panel(padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    Label("No certificate needed", systemImage: "puzzlepiece.extension")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Inject DEB packages, dylibs, and frameworks into a decrypted IPA. The app’s bundle identifier stays unchanged.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Label("Signing required before installation", systemImage: "signature")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.warning)
                    Text("The export is unsigned and cannot be installed directly. Sign it later with LoadSide or another compatible signing tool.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text("DEB scripts never run. LoadSide checks archive paths, binary compatibility, and dependencies before exporting.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("App options", isExpanded: $model.showAdvanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Display name (optional)", text: $model.displayName).inputField().accessibilityLabel("App display name override")
                            Toggle("Remove app extensions", isOn: $model.removeExtensions).toggleStyle(.checkbox)
                            if model.removeExtensions {
                                Text("The export will lose widgets, share actions, and other extension features.")
                                    .foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
                            }
                        }.font(.system(size: 11)).padding(.top, 10)
                    }.font(.system(size: 12, weight: .medium))
                }
            }
        }.disabled(model.isRunning)
    }

    private var extensionPlan: some View {
        VStack(alignment: .leading, spacing: 10) {
            let count = model.ipaInspection?.extensionCount ?? 0
            HStack {
                Text("Extension profiles").font(.system(size: 12, weight: .medium))
                Spacer()
                if model.ipaInspection != nil {
                    Text("\(count) found").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                extensionChoice(.reuseMain, title: "Reuse main profile (experimental)")
                extensionChoice(.matching, title: "Require matching profiles")
            }
            .disabled(model.removeExtensions)
            if !model.removeExtensions {
                if model.extensionProfilePolicy == .reuseMain {
                    Text("Uses matching profiles when available, then reuses the main profile for eligible extensions.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Experimental compatibility", isExpanded: $showCompatibilityDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Extensions keep their bundle IDs but may share the main app’s signing identity and keychain access. File importing, app groups, and other features may fail. Device behavior is unverified.")
                            if !model.compatibilityExtensionIdentifiers.isEmpty {
                                Text("Using shared identity: \(model.compatibilityExtensionIdentifiers.joined(separator: ", "))")
                                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }
                        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
                    }.font(.system(size: 11)).foregroundStyle(Palette.warning)
                } else {
                    Text("Each extension needs an authorized profile. A matching wildcard profile can cover more than one bundle.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !model.blockingExtensionIdentifiers.isEmpty {
                    InlineNotice(message: "Add matching profiles for \(model.blockingExtensionIdentifiers.count) extension(s) to continue.")
                    ForEach(model.blockingExtensionIdentifiers, id: \.self) { identifier in
                        Text(identifier).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    Button("Add extension profiles…", action: model.chooseProfiles).controlSize(.small)
                }
            }
            if count > 0 || model.removeExtensions {
                Divider().padding(.vertical, 2)
                Toggle("Remove app extensions", isOn: $model.removeExtensions).toggleStyle(.checkbox).font(.system(size: 12))
                if model.removeExtensions {
                    Text("The export will lose extension features such as widgets, share actions, and notification services.")
                        .font(.system(size: 11)).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("View extension identifiers", isExpanded: $showExtensionList) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(model.ipaInspection?.extensionBundleIdentifiers ?? [], id: \.self) { identifier in
                            let effective = model.identifierSuggestion?.identifier(forOriginalBundleIdentifier: identifier) ?? identifier
                            HStack(alignment: .top, spacing: 6) {
                                if model.unmatchedExtensionIdentifiers.contains(effective) && !model.removeExtensions {
                                    Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warning)
                                        .help(model.compatibilityExtensionIdentifiers.contains(effective) ? "Will reuse the main profile’s identity" : "Needs a matching profile")
                                }
                                Text(effective).textSelection(.enabled)
                            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 5).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 11))
            } else if model.ipaInspection != nil {
                Text("This app has no extensions.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if !model.unmatchedNestedAppIdentifiers.isEmpty {
                InlineNotice(message: "Nested apps need matching profiles: \(model.unmatchedNestedAppIdentifiers.joined(separator: ", ")). Main-profile reuse applies only to extensions.")
            }
        }
    }

    private func extensionChoice(_ policy: ExtensionProfilePolicy, title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.extensionProfilePolicy == policy },
            set: { model.selectExtensionProfilePolicy(policy, isSelected: $0) }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .accessibilityHint("Choose one extension profile policy. Selecting this option replaces the other selection.")
    }

    private var injections: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                SectionHeading(title: "Injected libraries", detail: model.jobMode == .sign ? "Optional · DEB, dylib, or framework" : "Add a DEB, dylib, or framework")
                Spacer()
                Button("Add…", action: model.chooseInjections).controlSize(.small)
            }
            Panel(padding: 13) {
                if model.injections.isEmpty {
                    HStack(spacing: 9) {
                        Image(systemName: "puzzlepiece.extension").foregroundStyle(.tertiary)
                        Text("Drop libraries or packages here. DEB install scripts are never executed.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }.frame(minHeight: 20)
                } else {
                    VStack(spacing: 12) {
                        ForEach(model.injections, id: \.self) { url in
                            FileRow(url: url, symbol: url.pathExtension == "deb" ? "shippingbox" : "puzzlepiece.extension") { model.injections.removeAll { $0 == url } }
                        }
                    }
                }
            }.dropDestination(for: URL.self) { urls, _ in model.accept(urls, kind: .injection) }
        }.disabled(model.isRunning)
    }

    private func currentJob(_ job: JobRecord) -> some View {
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    SectionHeading(title: job.status == .running ? "Export in progress" : "Last export")
                    Spacer()
                    StatusPill(status: job.status)
                    Button("Details") { model.selectedJobID = job.id; model.section = .activity }.controlSize(.small)
                }
                if job.status == .running {
                    ProgressView(value: job.events.map(\.fraction).max() ?? 0).progressViewStyle(.linear)
                    Text(job.events.last?.message ?? "Preparing the signing workspace…").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let result = job.result {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.output.lastPathComponent).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                            Text("\(result.signedCodeCount) code objects verified · \(result.injectedLibraryCount) libraries injected").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show in Finder") { model.reveal(job.output) }.disabled(!FileManager.default.fileExists(atPath: job.output.path))
                    }
                    if !result.warnings.isEmpty { InlineNotice(message: "\(result.warnings.count) warning(s) recorded. Review export details before installing.") }
                }
                if let result = job.injectionResult {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.output.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            Text("\(result.injectedLibraryCount) libraries injected · Unsigned")
                                .font(.system(size: 11)).foregroundStyle(Palette.warning)
                        }
                        Spacer(minLength: 4)
                        Button("Show in Finder") { model.reveal(job.output) }.disabled(!FileManager.default.fileExists(atPath: job.output.path))
                    }
                    Text("Sign this IPA before installation.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let failure = job.failure { InlineNotice(message: failure, color: job.status == .failed ? Palette.error : Palette.warning) }
                if let recovery = job.recovery { Text(recovery).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                if job.status == .failed || job.status == .cancelled {
                    Text(job.jobMode == .injectOnly ? "Review the app and injected libraries, then export again." : "Adjust the signing inputs, re-enter the P12 password if needed, then export again.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var exportBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(model.isRunning ? (model.isCancelling ? "Stopping safely…" : "\(model.currentJob?.events.last?.stage.title ?? "Preparing export")") : model.missingInputs,
                      systemImage: model.isRunning ? "arrow.triangle.2.circlepath" : (model.canSign ? "checkmark.circle.fill" : "circle.dotted"))
                    .font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text(model.isRunning ? "Keep LoadSide open until cleanup finishes." : model.jobMode == .sign ? "Choose the export destination next." : "Unsigned output · Sign before installation").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if model.isRunning {
                Button(model.isCancelling ? "Cancelling…" : "Cancel", action: model.cancel).adaptiveGlassButton().disabled(model.isCancelling)
            } else {
                Button(action: model.beginSigning) { Label(model.jobMode == .sign ? "Sign & Export…" : "Inject & Export…", systemImage: model.jobMode == .sign ? "signature" : "puzzlepiece.extension") }
                    .adaptiveGlassButton(prominent: true).controlSize(.large).disabled(!model.canSign)
                    .help(model.jobMode == .sign ? "Sign and export (⌘R)" : "Export an unsigned injected IPA (⌘R)")
            }
        }.padding(.horizontal, 16).padding(.vertical, 12).floatingControlSurface(cornerRadius: 16)
    }
}
