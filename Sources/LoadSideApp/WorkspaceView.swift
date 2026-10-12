import SwiftUI
import LoadSideCore

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var isDropTarget = false
    @State private var showSaveProfile = false
    @State private var showExtensionList = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    applicationInput
                    if let storageNotice = model.storageNotice { InlineNotice(message: storageNotice) }
                    HStack(alignment: .top, spacing: 20) {
                        credentials.frame(maxWidth: .infinity, alignment: .topLeading)
                        signingPlan.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    injections
                    if let job = model.currentJob { currentJob(job) }
                }.padding(24)
            }
            .scrollIndicators(.automatic)
            Divider()
            exportBar
        }
        .sheet(isPresented: $showSaveProfile) { SaveSigningProfileSheet(model: model) }
    }

    private var applicationInput: some View {
        HStack(spacing: 15) {
            Image(systemName: model.ipa == nil ? "app.dashed" : "app.fill")
                .font(.system(size: 30, weight: .light)).foregroundStyle(model.ipa == nil ? Color.secondary : Palette.accent)
                .frame(width: 54, height: 58)
                .background(Palette.accent.opacity(model.ipa == nil ? 0.035 : 0.075), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.ipaInspection?.displayName ?? model.ipa?.deletingPathExtension().lastPathComponent ?? "Choose an app to sign")
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
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
                    Text("Drop a decrypted IPA here, or open a file.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Your original files stay unchanged.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button(model.ipa == nil ? "Open IPA…" : "Change…", action: model.chooseIPA).controlSize(.regular).disabled(model.isRunning)
                .help("Choose an IPA (⌘O)")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDropTarget ? Palette.accent.opacity(0.1) : Palette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isDropTarget ? Palette.accent : Palette.separator))
        .dropDestination(for: URL.self) { urls, _ in model.accept(urls, kind: .ipa) } isTargeted: { isDropTarget = $0 }
        .overlay(alignment: .bottomLeading) {
            // The detailed error is placed in the signing plan to keep this row compact.
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
            Panel {
                VStack(alignment: .leading, spacing: 15) {
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
                            Text("A P12 containing your signing certificate and private key.").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        SecureField("P12 password", text: $model.password).inputField().accessibilityLabel("Certificate password")
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Provisioning profiles").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Add…", action: model.chooseProfiles).controlSize(.small)
                        }
                        if model.profiles.isEmpty {
                            Text("Add a .mobileprovision for the app and each retained extension.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.profiles, id: \.self) { url in profileRow(url) }
                    }
                    Divider()
                    HStack {
                        Image(systemName: "key.viewfinder").foregroundStyle(.tertiary)
                        Text("Reuse these files in future sessions.").font(.system(size: 10)).foregroundStyle(.secondary)
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
            SectionHeading(title: "Signing plan")
            Panel {
                VStack(alignment: .leading, spacing: 15) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bundle identifier").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Picker("Bundle identifier policy", selection: $model.identifierPolicy) {
                            Text("Automatic").tag(BundleIdentifierPolicy.automatic)
                            Text("Keep original").tag(BundleIdentifierPolicy.preserve)
                        }.pickerStyle(.segmented).labelsHidden()
                        if let suggestion = model.identifierSuggestion {
                            Text(suggestion.effectiveIdentifier).font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                            if suggestion.changesIdentifier {
                                Text("Changed from \(suggestion.originalIdentifier)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                InlineNotice(message: suggestion.reason, color: Palette.accent, symbol: "arrow.triangle.2.circlepath")
                            } else {
                                Text(suggestion.reason).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text(model.identifierPolicy == .automatic ? "Keeps the app’s ID when authorized; otherwise uses the single matching exact ID from your profiles." : "Requires a profile that authorizes the app’s current identifier.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let error = model.identifierSuggestionError {
                            InlineNotice(message: error, color: Palette.error)
                            if let recovery = model.identifierSuggestionRecovery { Text(recovery).font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        if let error = model.ipaInspectionError {
                            InlineNotice(message: error, color: Palette.error)
                            if let recovery = model.ipaInspectionRecovery { Text(recovery).font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        if model.identifierSuggestion != nil {
                            Text("Profile-based plan. The P12 and certificate membership are verified during signing.")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    Divider()
                    extensionPlan
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Entitlements").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Picker("Entitlement policy", selection: $model.policy) {
                            Text("Strict").tag(EntitlementPolicy.strict)
                            Text("Compatible").tag(EntitlementPolicy.compatible)
                        }.pickerStyle(.segmented).labelsHidden()
                        Text(model.policy == .strict ? "Stops if the profiles do not authorize a requested capability." : "Removes unsupported entitlements. Push notifications, app groups, and other capabilities may stop working. Every removal is recorded.")
                            .font(.system(size: 11)).foregroundStyle(model.policy == .strict ? Color.secondary : Palette.warning).fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    DisclosureGroup("Overrides", isExpanded: $model.showAdvanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Bundle ID (optional)", text: $model.bundleIdentifier).inputField().accessibilityLabel("Explicit bundle identifier override")
                            Text("An explicit ID takes precedence over Automatic and must be authorized by a supplied profile.").font(.system(size: 10)).foregroundStyle(.secondary)
                            TextField("Display name (optional)", text: $model.displayName).inputField().accessibilityLabel("App display name override")
                        }.padding(.top, 8)
                    }.font(.system(size: 11, weight: .medium))
                }
            }
        }.disabled(model.isRunning)
    }

    private var extensionPlan: some View {
        VStack(alignment: .leading, spacing: 8) {
            let count = model.ipaInspection?.extensionCount ?? 0
            HStack {
                Text("App extensions").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if model.ipaInspection != nil { Text("\(count) found").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if count > 0 || model.removeExtensions {
                if !model.unmatchedExtensionIdentifiers.isEmpty && !model.removeExtensions {
                    InlineNotice(message: "\(model.unmatchedExtensionIdentifiers.count) extension\(model.unmatchedExtensionIdentifiers.count == 1 ? " has" : "s have") no matching profile. Add profiles, or choose to remove all \(count) extensions below.")
                }
                Toggle(count > 0 ? "Remove all \(count) app extensions" : "Remove app extensions", isOn: $model.removeExtensions).font(.system(size: 12))
                Text(model.removeExtensions ? "Their features will be absent from the export, including widgets, share actions, and notifications provided by extensions." : "Each retained extension needs its own matching profile. If you only have the main app’s profile, explicitly remove the extensions.")
                    .font(.system(size: 11)).foregroundStyle(model.removeExtensions ? Palette.warning : Color.secondary).fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("View extension identifiers", isExpanded: $showExtensionList) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.ipaInspection?.extensionBundleIdentifiers ?? [], id: \.self) { identifier in
                            let effective = model.identifierSuggestion?.identifier(forOriginalBundleIdentifier: identifier) ?? identifier
                            HStack(alignment: .top, spacing: 5) {
                                if model.unmatchedExtensionIdentifiers.contains(effective) {
                                    Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warning).help("No matching supplied profile")
                                }
                                Text(effective).textSelection(.enabled)
                            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 5).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 10))
            } else if model.ipaInspection != nil {
                Text("This app has no app extensions.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("The app’s extensions appear after inspection. Removal is always an explicit choice.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let nested = model.ipaInspection?.nestedAppBundleIdentifiers, !nested.isEmpty {
                Text("\(nested.count) nested app(s) still require matching profiles, even when extensions are removed.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var injections: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                SectionHeading(title: "Injected libraries", detail: "Optional · DEB, dylib, or framework")
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
        Panel {
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
                if let failure = job.failure { InlineNotice(message: failure, color: job.status == .failed ? Palette.error : Palette.warning) }
                if let recovery = job.recovery { Text(recovery).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                if job.status == .failed || job.status == .cancelled {
                    Text("Adjust the inputs above, re-enter the P12 password if needed, then export again.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var exportBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isRunning ? (model.isCancelling ? "Stopping safely…" : "\(model.currentJob?.events.last?.stage.title ?? "Preparing export")") : model.missingInputs)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(model.isRunning ? "Keep LoadSide open until cleanup finishes." : "The export destination is chosen next.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if model.isRunning {
                Button(model.isCancelling ? "Cancelling…" : "Cancel", action: model.cancel).disabled(model.isCancelling)
            } else {
                Button("Sign & Export…", action: model.beginSigning).buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canSign)
                    .help("Sign and export (⌘R)")
            }
        }.padding(.horizontal, 24).padding(.vertical, 15).background(.bar)
    }
}
