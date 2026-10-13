import LoadSideCore
import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isDropTarget = false
    @State private var isInjectionDropTarget = false
    @State private var showSaveProfile = false
    @State private var showExtensionList = false
    @State private var showCompatibilityDetails = false
    @State private var showExtensionOptions = false
    @State private var showEntitlements = false

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        workspaceHeading
                        applicationInput
                        if let error = model.ipaInspectionError {
                            InlineNotice(message: error + " " + (model.ipaInspectionRecovery ?? ""), color: Palette.error)
                        }
                        if let job = model.currentJob { currentJob(job) }
                        if geometry.size.width >= AppMetrics.workspaceColumnsWidth {
                            HStack(alignment: .top, spacing: 24) {
                                VStack(alignment: .leading, spacing: 24) {
                                    if model.jobMode == .sign { credentials }
                                    injections
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                Group {
                                    if model.jobMode == .sign { signingPlan } else { injectionPlan }
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        } else {
                            if model.jobMode == .sign { credentials }
                            if model.jobMode == .sign { signingPlan } else { injectionPlan }
                            injections
                        }
                        if let notice = model.storageNotice { InlineNotice(message: notice) }
                    }
                    .padding(AppMetrics.pagePadding)
                    .frame(maxWidth: 1280)
                    .frame(maxWidth: .infinity)
                    .id("workspace.top")
                }
                .onChange(of: model.jobMode) { _, _ in proxy.scrollTo("workspace.top", anchor: .top) }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    exportBar
                        .frame(maxWidth: 1232)
                        .padding(.horizontal, AppMetrics.pagePadding)
                        .padding(.bottom, 16).padding(.top, 8)
                }
            }
        }
        .sheet(isPresented: $showSaveProfile) { SaveSigningProfileSheet(model: model) }
    }

    private var workspaceHeading: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 22) {
                PageHeading(
                    title: "Prepare an app",
                    detail: model.jobMode == .sign
                        ? "Choose an app and signing identity to create your export."
                        : "Add libraries to an app, then sign the exported IPA later.")
                Spacer(minLength: 13)
                workflowPicker.frame(width: 290)
            }
            VStack(alignment: .leading, spacing: 11) {
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
        Button(action: model.chooseIPA) {
            HStack(spacing: 17) {
                SymbolTile(
                    symbol: model.ipa == nil ? "square.and.arrow.down" : "app.fill", color: model.ipa == nil ? .accentColor : .secondary,
                    size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.ipaInspection?.displayName ?? model.ipa?.deletingPathExtension().lastPathComponent ?? "Add an IPA")
                        .font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    if let ipa = model.ipa {
                        Text(ipa.lastPathComponent).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(ipa.path)
                        if model.isInspectingIPA {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Inspecting application…")
                            }.font(.system(size: 12)).foregroundStyle(.secondary)
                        } else if let inspection = model.ipaInspection {
                            HStack(spacing: 8) {
                                Text(inspection.bundleIdentifier).lineLimit(1).truncationMode(.middle)
                                Text("·")
                                Text("\(inspection.extensionCount) extensions")
                            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Drop a decrypted IPA here. Your original stays unchanged.").font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 9)
                Text(model.ipa == nil ? "Open IPA…" : "Change…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 15).padding(.vertical, 7)
                    .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isDropTarget ? Palette.accent.opacity(0.1) : Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    isDropTarget ? Palette.accent : Color.primary.opacity(contrast == .increased ? 0.65 : 0.35),
                    style: StrokeStyle(lineWidth: 2, dash: model.ipa == nil ? [6, 4] : []))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning || model.isManagingSigningProfiles)
        .help("Choose a decrypted IPA (⌘O)")
        .accessibilityLabel(model.ipa == nil ? "Add an IPA" : "Change IPA")
        .accessibilityValue(model.ipa?.lastPathComponent ?? "No file selected")
        .accessibilityIdentifier("workspace.ipa")
        .dropDestination(for: URL.self) { urls, _ in
            model.accept(urls, kind: .ipa)
        } isTargeted: {
            isDropTarget = $0
        }
        .overlay(alignment: .bottomLeading) {
            if model.ipaInspectionError != nil { Rectangle().fill(Palette.error).frame(width: 3).padding(.vertical, 13) }
        }
    }

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeading(title: "Signing identity")
                Spacer()
                Button("Manage") { model.section = .signingProfiles }.buttonStyle(.link).font(.system(size: 12))
            }
            Panel(padding: 15) {
                VStack(alignment: .leading, spacing: 11) {
                    Picker(
                        "Saved profile",
                        selection: Binding<UUID?>(
                            get: { model.selectedSigningProfileID }, set: { id in Task { await model.selectSigningProfile(id) } })
                    ) {
                        Text("Imported files").tag(nil as UUID?)
                        ForEach(model.savedSigningProfiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                    }.font(.system(size: 13)).disabled(model.isManagingSigningProfiles)
                    if model.isManagingSigningProfiles {
                        ProgressView("Updating signing profile…").controlSize(.small).font(.system(size: 12))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("Certificate").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            Button(model.certificate == nil ? "Import P12…" : "Replace…", action: model.chooseCertificate).controlSize(
                                .regular)
                        }
                        if let certificate = model.certificate {
                            FileRow(url: certificate, symbol: "key.horizontal") {
                                model.certificate = nil
                                model.password = ""
                            }
                        } else {
                            Text("Import your Apple certificate and private key.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        SecureField("P12 password", text: $model.password).inputField().accessibilityLabel("Certificate password")
                        if model.selectedSigningProfile?.remembersPassword == true && model.password.isEmpty {
                            Label("Saved password will be requested from Keychain when you sign.", systemImage: "lock.shield")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("Provisioning profiles").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Add…", action: model.chooseProfiles).controlSize(.regular)
                        }
                        if model.profiles.isEmpty {
                            Text("Add a .mobileprovision for the app and its extensions.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(model.profiles, id: \.self) { url in profileRow(url) }
                    }
                    Divider()
                    HStack {
                        Image(systemName: "key.viewfinder").foregroundStyle(.secondary)
                        Text("Save this identity for next time").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Save…") { showSaveProfile = true }.controlSize(.regular)
                            .disabled(!model.canSaveSigningProfile)
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.accept(urls.filter { ["p12", "pfx", "mobileprovision"].contains($0.pathExtension.lowercased()) })
            }
            if let notice = model.savedProfileNotice { InlineNotice(message: notice, color: Palette.accent, symbol: "info.circle") }
        }.disabled(model.isRunning || model.isManagingSigningProfiles)
    }

    @ViewBuilder private func profileRow(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
                Text(profileName(url)).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                RemoveButton(label: "Remove \(url.lastPathComponent)") { model.profiles.removeAll { $0 == url } }
            }.help(url.path)
            switch model.profileInspections[url] {
            case .valid(let profile):
                Text(profile.applicationIdentifier).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(
                    .enabled)
                Text(
                    "\(profile.distribution) · \(profile.deviceCount) devices · Expires \(profile.expiresAt.formatted(date: .abbreviated, time: .omitted))"
                )
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if profile.distribution == "App Store" {
                    InlineNotice(
                        message:
                            "App Store profiles cannot authorize a direct-install export. Choose an Ad Hoc, Development, or Enterprise profile."
                    )
                }
            case .invalid(let message, let recovery):
                InlineNotice(message: message + " " + recovery, color: Palette.error)
                Button("Check again") { model.inspectProfile(url) }.buttonStyle(.link).font(.system(size: 12))
            case .inspecting, .none:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Validating profile…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 2)
    }

    private func profileName(_ url: URL) -> String {
        if case .valid(let profile) = model.profileInspections[url] { return profile.name }
        return url.lastPathComponent
    }

    private var signingPlan: some View {
        SigningOptionsView(
            model: model, showExtensionList: $showExtensionList,
            showCompatibilityDetails: $showCompatibilityDetails,
            showExtensionOptions: $showExtensionOptions, showEntitlements: $showEntitlements)
    }

    private var injectionPlan: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Unsigned export")
            Panel(padding: 18) {
                VStack(alignment: .leading, spacing: 15) {
                    Label("No certificate needed", systemImage: "puzzlepiece.extension")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Inject DEB packages, dylibs, and frameworks into a decrypted IPA. The app’s bundle identifier stays unchanged.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Label("Signing required before installation", systemImage: "signature")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.warning)
                    Text(
                        "The export is unsigned and cannot be installed directly. Sign it later with LoadSide or another compatible signing tool."
                    )
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text("DEB scripts never run. LoadSide checks archive paths, binary compatibility, and dependencies before exporting.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("App options", isExpanded: $model.showAdvanced) {
                        VStack(alignment: .leading, spacing: 11) {
                            TextField("Display name (optional)", text: $model.displayName).inputField().accessibilityLabel(
                                "App display name override")
                            Toggle("Remove app extensions", isOn: $model.removeExtensions).toggleStyle(.checkbox)
                            if model.removeExtensions {
                                Text("The export will lose widgets, share actions, and other extension features.")
                                    .foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
                            }
                        }.font(.system(size: 12)).padding(.top, 11)
                    }.font(.system(size: 13, weight: .medium))
                }
            }
        }
        .disabled(model.isRunning)
    }

    private var injections: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeading(
                    title: "Injected libraries",
                    detail: model.jobMode == .sign ? "Optional · DEB, dylib, or framework" : "Add a DEB, dylib, or framework")
                Spacer()
                Button("Add…", action: model.chooseInjections).controlSize(.regular)
            }
            Group {
                if model.injections.isEmpty {
                    Button(action: model.chooseInjections) {
                        HStack(spacing: 12) {
                            Image(systemName: "puzzlepiece.extension").font(.system(size: 22)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Drop libraries or packages here")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Or click to browse. DEB install scripts are never executed.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add injected libraries")
                    .accessibilityHint("Choose DEB packages, dynamic libraries, or frameworks.")
                    .accessibilityIdentifier("workspace.injections")
                } else {
                    Panel(padding: 18) {
                        VStack(spacing: 13) {
                            ForEach(model.injections, id: \.self) { url in
                                FileRow(url: url, symbol: url.pathExtension == "deb" ? "shippingbox" : "puzzlepiece.extension") {
                                    model.injections.removeAll { $0 == url }
                                }
                            }
                        }
                    }
                }
            }
            .background(isInjectionDropTarget ? Palette.accent.opacity(0.1) : Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    isInjectionDropTarget ? Palette.accent : Color.primary.opacity(contrast == .increased ? 0.65 : 0.35),
                    style: StrokeStyle(lineWidth: 2, dash: model.injections.isEmpty ? [6, 4] : [])
                )
                .allowsHitTesting(false)
            )
            .dropDestination(for: URL.self) { urls, _ in
                model.accept(urls, kind: .injection)
            } isTargeted: {
                isInjectionDropTarget = $0
            }
        }.disabled(model.isRunning)
    }

    private func currentJob(_ job: JobRecord) -> some View {
        Panel(padding: 15) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeading(
                        title: job.status == .running
                            ? (model.isCancelling ? "Stopping safely…" : "Export in progress")
                            : (job.status == .completed ? "Export complete" : "Last export"))
                    Spacer()
                    StatusPill(status: job.status)
                    Button("Details") {
                        model.selectedJobID = job.id
                        model.section = .activity
                    }.controlSize(.regular).accessibilityIdentifier("workspace.exportDetails")
                }
                if job.status == .running {
                    ProgressView(value: job.events.map(\.fraction).max() ?? 0).progressViewStyle(.linear)
                        .accessibilityLabel("Export progress")
                    Text(job.events.last?.message ?? "Preparing the export workspace…").font(.system(size: 12)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let result = job.result {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.output.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(
                                .middle
                            ).textSelection(.enabled).help(result.output.path)
                            Text(
                                "\(result.signedCodeCount) code objects locally verified · \(result.injectedLibraryCount) libraries injected"
                            )
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show in Finder") { model.reveal(job.output) }.disabled(
                            !FileManager.default.fileExists(atPath: job.output.path))
                    }
                    if !result.warnings.isEmpty {
                        InlineNotice(message: "\(result.warnings.count) warning(s) recorded. Review export details before installing.")
                    }
                }
                if let result = job.injectionResult {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.output.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(2).truncationMode(
                                .middle
                            ).textSelection(.enabled)
                            Text("\(result.injectedLibraryCount) libraries injected · Unsigned")
                                .font(.system(size: 12)).foregroundStyle(Palette.warning)
                        }
                        Spacer(minLength: 4)
                        Button("Show in Finder") { model.reveal(job.output) }.disabled(
                            !FileManager.default.fileExists(atPath: job.output.path))
                    }
                    Text("Sign this IPA before installation.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if job.status == .completed, !FileManager.default.fileExists(atPath: job.output.path) {
                    Text("The exported file has moved or is no longer available at its original location.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let failure = job.failure {
                    InlineNotice(message: failure, color: job.status == .failed ? Palette.error : Palette.warning)
                }
                if let recovery = job.recovery {
                    Text(recovery).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if job.status == .failed || job.status == .cancelled {
                    Text(
                        job.jobMode == .injectOnly
                            ? "Review the app and injected libraries, then export again."
                            : "Adjust the signing inputs, re-enter the P12 password if needed, then export again."
                    ).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var exportBar: some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    model.isRunning
                        ? (model.isCancelling ? "Stopping safely…" : "\(model.currentJob?.events.last?.stage.title ?? "Preparing export")")
                        : model.missingInputs,
                    systemImage: model.isRunning
                        ? "arrow.triangle.2.circlepath" : (model.canSign ? "checkmark.circle.fill" : "circle.dotted")
                )
                .font(.system(size: 13, weight: .medium)).lineLimit(2)
                Text(
                    model.isRunning
                        ? "Keep LoadSide open until cleanup finishes."
                        : model.jobMode == .sign
                            ? (model.canSign ? "Choose the export destination next." : "Complete the inputs above to continue.")
                            : "Unsigned output · Sign before installation"
                ).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 11)
            if model.isRunning {
                Button(model.isCancelling ? "Cancelling…" : "Cancel", action: model.cancel).buttonStyle(.bordered).accessibilityIdentifier(
                    "workspace.cancel"
                ).disabled(
                    model.isCancelling)
            } else {
                Button(action: model.beginSigning) {
                    Label(
                        model.jobMode == .sign ? "Sign & Export…" : "Inject & Export…",
                        systemImage: model.jobMode == .sign ? "signature" : "puzzlepiece.extension")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canSign)
                .accessibilityIdentifier("export")
                .help(model.jobMode == .sign ? "Sign and export (⌘R)" : "Export an unsigned injected IPA (⌘R)")
            }
        }.padding(.horizontal, 18).padding(.vertical, 13).floatingControlSurface(cornerRadius: 18)
    }
}
