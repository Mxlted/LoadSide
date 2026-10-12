import SwiftUI
import LoadSideCore

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var dropTargeted = false
    private let pipeline: [SigningStage] = [.preparing, .inspecting, .credentials, .entitlements, .injecting, .signing, .verifying, .exporting]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A better way to sign.").font(.system(size: 29, weight: .semibold)).tracking(-0.8)
                        Text("Bring your app and credentials. Sign, verify, and export in one workspace.")
                            .font(.system(size: 12)).foregroundStyle(Studio.muted)
                    }
                    Spacer()
                    Button(action: model.reset) { Label("New session", systemImage: "plus") }
                        .buttonStyle(StudioButtonStyle()).disabled(model.isRunning)
                }
                if let storageNotice = model.storageNotice { NoticeView(message: storageNotice) }
                HStack(alignment: .top, spacing: 22) {
                    VStack(spacing: 18) {
                        applicationCard
                        credentialsCard
                        injectionCard
                        optionsCard
                    }.frame(maxWidth: .infinity)
                    VStack(spacing: 18) {
                        sessionCard
                        pipelineCard
                    }.frame(width: 278)
                }
            }.padding(30)
        }
        .scrollIndicators(.hidden)
    }

    private var applicationCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 20) {
                CardHeading(number: "01", title: "Application", detail: "Start with an unsigned or previously signed, decrypted IPA.")
                Button(action: model.chooseIPA) {
                    VStack(spacing: 12) {
                        Image(systemName: model.ipa == nil ? "shippingbox" : "app.dashed")
                            .font(.system(size: 29, weight: .light)).foregroundStyle(Studio.mint)
                            .frame(height: 36)
                        if let ipa = model.ipa {
                            Text(ipa.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text("Click to replace, or drop a different IPA").font(.system(size: 11)).foregroundStyle(Studio.muted)
                        } else {
                            Text("Drop your IPA here").font(.system(size: 15, weight: .medium))
                            HStack(spacing: 4) {
                                Text("or").foregroundStyle(Studio.muted)
                                Text("browse files").foregroundStyle(Studio.mint)
                            }.font(.system(size: 12))
                        }
                        Text(".IPA  ·  DECRYPTED APPS ONLY").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.2).foregroundStyle(Studio.muted.opacity(0.75)).padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 27).padding(.horizontal, 16)
                    .background(Studio.mint.opacity(dropTargeted ? 0.09 : 0.025), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Studio.mint.opacity(dropTargeted ? 0.8 : 0.24), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
                    .contentShape(RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain).disabled(model.isRunning)
                    .dropDestination(for: URL.self) { urls, _ in model.accept(urls, kind: .ipa) } isTargeted: { dropTargeted = $0 }
                    .accessibilityLabel(model.ipa == nil ? "Choose decrypted IPA file" : "Replace \(model.ipa!.lastPathComponent)")
                HStack(spacing: 7) {
                    Image(systemName: "info.circle").font(.system(size: 11))
                    Text("The original app is never modified.").font(.system(size: 11))
                }.foregroundStyle(Studio.muted)
            }
        }
    }

    private var credentialsCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 19) {
                CardHeading(number: "02", title: "Signing credentials", detail: "Use a matching certificate and provisioning profile for each app bundle.")
                VStack(alignment: .leading, spacing: 9) {
                    InputLabel(text: "Certificate")
                    if let certificate = model.certificate {
                        FileRow(url: certificate, symbol: "person.badge.key", remove: { model.certificate = nil })
                    } else {
                        Button(action: model.chooseCertificate) {
                            HStack {
                                Image(systemName: "person.badge.key").foregroundStyle(Studio.mint)
                                Text("Choose P12 certificate")
                                Spacer()
                                Text(".p12 / .pfx").font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted)
                                Image(systemName: "plus").foregroundStyle(Studio.muted)
                            }.frame(maxWidth: .infinity)
                        }.buttonStyle(StudioButtonStyle())
                    }
                }.dropDestination(for: URL.self) { urls, _ in model.accept(urls, kind: .certificate) }
                VStack(alignment: .leading, spacing: 9) {
                    InputLabel(text: "Certificate password")
                    SecureField("Enter password, or leave blank if none", text: $model.password).studioField()
                        .accessibilityLabel("Certificate password")
                    HStack(spacing: 5) {
                        Image(systemName: "lock").font(.system(size: 9))
                        Text("Never saved. Cleared when signing starts.").font(.system(size: 10))
                    }.foregroundStyle(Studio.muted)
                }
                Rectangle().fill(Studio.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        InputLabel(text: "Provisioning profiles")
                        Spacer()
                        if !model.profiles.isEmpty { Text("\(model.profiles.count) added").font(.system(size: 10)).foregroundStyle(Studio.muted) }
                    }
                    ForEach(model.profiles, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 8) {
                            FileRow(url: url, symbol: "checkmark.seal", remove: { model.profiles.removeAll { $0 == url } })
                            profileDetails(url)
                        }
                    }
                    Button(action: model.chooseProfiles) { Label(model.profiles.isEmpty ? "Add mobileprovision files" : "Add another profile", systemImage: "plus") }
                        .buttonStyle(StudioButtonStyle())
                    Text("Extensions and watch apps can need their own profile. LoadSide matches profiles to bundle identifiers.")
                        .font(.system(size: 11)).foregroundStyle(Studio.muted).lineSpacing(3)
                }.dropDestination(for: URL.self) { urls, _ in model.accept(urls, kind: .profile) }
            }.disabled(model.isRunning)
        }
    }

    private var injectionCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 17) {
                CardHeading(number: "03", title: "Libraries & tweaks", detail: "Optional · Inject libraries, then re-sign all embedded code.")
                ForEach(model.injections, id: \.self) { url in
                    FileRow(url: url, symbol: "puzzlepiece.extension", remove: { model.injections.removeAll { $0 == url } })
                }
                Button(action: model.chooseInjections) {
                    HStack {
                        Label("Add injection", systemImage: "plus")
                        Spacer()
                        Text("DEB · DYLIB · FRAMEWORK").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(Studio.muted)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(StudioButtonStyle())
                Text("DEB payloads are inspected without executing package scripts. Libraries must support the app’s architecture; dependencies must be supplied.")
                    .font(.system(size: 11)).foregroundStyle(Studio.muted).lineSpacing(3)
            }.disabled(model.isRunning)
                .dropDestination(for: URL.self) { urls, _ in model.accept(urls, kind: .injection) }
        }
    }

    private var optionsCard: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 17) {
                Button { withAnimation(.easeInOut(duration: 0.18)) { model.showAdvanced.toggle() } } label: {
                    HStack {
                        CardHeading(number: "04", title: "Signing options", detail: "\(model.policy == .strict ? "Strict" : "Compatible") entitlements · \(model.removeExtensions ? "Remove app extensions enabled" : "Optional app overrides")")
                        Image(systemName: model.showAdvanced ? "chevron.up" : "chevron.down").font(.system(size: 11)).foregroundStyle(Studio.muted)
                    }
                }.buttonStyle(.plain)
                if model.showAdvanced {
                    VStack(alignment: .leading, spacing: 9) {
                        InputLabel(text: "Bundle identifier", optional: true)
                        TextField("Keep original identifier", text: $model.bundleIdentifier).studioField().accessibilityLabel("Bundle identifier override")
                        Text("Changing identifiers can affect keychain access, app groups, push notifications, and app extensions.")
                            .font(.system(size: 11)).foregroundStyle(Studio.muted).lineSpacing(3)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        InputLabel(text: "Display name", optional: true)
                        TextField("Keep original display name", text: $model.displayName).studioField().accessibilityLabel("Display name override")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Remove app extensions", isOn: $model.removeExtensions)
                            .toggleStyle(.switch)
                            .font(.system(size: 12, weight: .medium))
                            .accessibilityHint("Removes all app extension bundles from the export. The original IPA is preserved.")
                        Text("Removes all app extension bundles from the exported IPA. Features such as Safari extensions, widgets, and share actions will be unavailable. Useful when you only have a main-app profile. Nested apps still need their own profiles.")
                            .font(.system(size: 11)).foregroundStyle(model.removeExtensions ? Studio.amber : Studio.muted).lineSpacing(3)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        InputLabel(text: "Entitlement policy")
                        Picker("Entitlement policy", selection: $model.policy) {
                            Text("Strict").tag(EntitlementPolicy.strict)
                            Text("Compatible").tag(EntitlementPolicy.compatible)
                        }.pickerStyle(.segmented).labelsHidden()
                        Text(model.policy == .strict
                             ? "Recommended. Stop if requested entitlements are not authorized by the selected profile. This protects app capabilities from being silently removed."
                             : "Remove entitlements that the profile does not authorize and report each change. The app may lose capabilities or fail at runtime.")
                            .font(.system(size: 11)).foregroundStyle(model.policy == .strict ? Studio.muted : Studio.amber).lineSpacing(3)
                    }
                }
            }.disabled(model.isRunning)
        }
    }

    private var sessionCard: some View {
        StudioCard(padding: 20) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("EXPORT SESSION").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(Studio.muted)
                    Spacer()
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 14)).foregroundStyle(Studio.muted)
                }
                Text(model.isRunning ? (model.isCancelling ? "Cancelling safely…" : "Signing your app.") : sessionTitle)
                    .font(.system(size: 19, weight: .semibold)).tracking(-0.4)
                if let job = model.currentJob {
                    if job.status == .completed, let result = job.result {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Verified & exported", systemImage: "checkmark.seal.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Studio.mint)
                            Text(result.displayName).font(.system(size: 13, weight: .medium))
                            Text(result.bundleIdentifier).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted).textSelection(.enabled)
                            Text("\(result.signedCodeCount) signed code objects · \(result.injectedLibraryCount) injected libraries")
                                .font(.system(size: 10)).foregroundStyle(Studio.muted)
                            ForEach(result.warnings, id: \.self) { warning in NoticeView(message: warning) }
                            Button { model.reveal(result.output) } label: { Label("Show in Finder", systemImage: "folder") }.buttonStyle(StudioButtonStyle())
                        }
                    } else if let failure = job.failure {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(failure).font(.system(size: 12, weight: .medium)).foregroundStyle(job.status == .failed ? Studio.red : Studio.amber).textSelection(.enabled)
                            if let code = job.errorCode { Text(code).font(.system(size: 9, design: .monospaced)).foregroundStyle(Studio.muted) }
                            if let recovery = job.recovery { Text(recovery).font(.system(size: 11)).foregroundStyle(Studio.muted).lineSpacing(3).textSelection(.enabled) }
                        }
                    } else if model.isRunning {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(value: job.events.map(\.fraction).max() ?? 0).tint(Studio.mint)
                            Text(job.events.last?.message ?? "Preparing a private workspace…").font(.system(size: 11)).foregroundStyle(Studio.muted).lineSpacing(3)
                        }
                    }
                } else {
                    Text("Your app, signed with your certificate. We validate, sign, verify, and package the export.")
                        .font(.system(size: 12)).foregroundStyle(Studio.muted).lineSpacing(4)
                }
                Rectangle().fill(Studio.line).frame(height: 1)
                VStack(spacing: 11) {
                    readiness("Decrypted IPA", ready: model.ipa != nil)
                    readiness("P12 certificate", ready: model.certificate != nil)
                    readiness("Provisioning profile", ready: model.profilesReady)
                }
                if model.removeExtensions {
                    Label("Remove app extensions enabled", systemImage: "minus.circle")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Studio.amber)
                }
                if model.isRunning {
                    Button(action: model.cancel) {
                        HStack { Spacer(); Label(model.isCancelling ? "Cancelling…" : "Cancel operation", systemImage: "stop.circle"); Spacer() }
                    }.buttonStyle(StudioButtonStyle()).disabled(model.isCancelling)
                } else {
                    Button(action: model.beginSigning) {
                        HStack { Spacer(); Text("Sign & Export"); Image(systemName: "arrow.up.right"); Spacer() }
                    }.buttonStyle(StudioButtonStyle(primary: true)).disabled(!model.canSign)
                    Text(model.missingInputs).font(.system(size: 10)).foregroundStyle(Studio.muted).frame(maxWidth: .infinity)
                }
                if let job = model.currentJob {
                    Button { model.exportDiagnostics(job) } label: { Label("Export diagnostics", systemImage: "doc.text") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Studio.muted)
                    Button { model.selectedJobID = job.id; model.section = .activity } label: { Label("View full activity", systemImage: "list.bullet.rectangle") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Studio.muted)
                }
            }
        }
    }

    private var sessionTitle: String {
        guard let job = model.currentJob else { return "Ready when you are." }
        switch job.status {
        case .completed: return "Your export is ready."
        case .failed: return "Let’s resolve this."
        case .cancelled: return "Operation cancelled."
        case .interrupted: return "Session interrupted."
        case .running: return "Preparing your app."
        }
    }

    @ViewBuilder
    private func profileDetails(_ url: URL) -> some View {
        switch model.profileInspections[url] {
        case .inspecting, .none:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Verifying profile signature and validity…").font(.system(size: 10)).foregroundStyle(Studio.muted)
            }.padding(.horizontal, 5)
        case .valid(let profile):
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Studio.mint)
                    Text(profile.name).fontWeight(.medium)
                    Spacer(minLength: 3)
                    Text(profile.distribution).foregroundStyle(profile.distribution == "App Store" ? Studio.amber : Studio.mint)
                }.font(.system(size: 10))
                Text(profile.applicationIdentifier).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted).textSelection(.enabled)
                Text("Team \(profile.teamIdentifier) · Expires \(profile.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 10)).foregroundStyle(Studio.muted)
                if profile.distribution == "App Store" {
                    Text("This profile cannot authorize direct installation. Add a Development, Ad Hoc, or Enterprise profile instead.")
                        .font(.system(size: 10)).foregroundStyle(Studio.amber).lineSpacing(3)
                } else if profile.deviceCount > 0 {
                    Text("\(profile.deviceCount) registered devices · Certificate match is checked during signing")
                        .font(.system(size: 9)).foregroundStyle(Studio.muted)
                }
            }.padding(.horizontal, 5).padding(.bottom, 3)
        case .invalid(let message, let recovery):
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Studio.red)
                    Text(message).font(.system(size: 10, weight: .medium)).foregroundStyle(Studio.red)
                    Spacer(minLength: 0)
                    Button { model.inspectProfile(url) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(Studio.muted).help("Recheck provisioning profile").accessibilityLabel("Recheck \(url.lastPathComponent)")
                }
                Text(recovery).font(.system(size: 10)).foregroundStyle(Studio.muted).lineSpacing(3)
            }.padding(.horizontal, 5).padding(.bottom, 3)
        }
    }

    private func readiness(_ title: String, ready: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(ready ? Studio.mint : Studio.muted.opacity(0.5)).font(.system(size: 12))
            Text(title).font(.system(size: 11)).foregroundStyle(ready ? Color.white.opacity(0.85) : Studio.muted)
            Spacer()
        }
    }

    private var pipelineCard: some View {
        StudioCard(padding: 20) {
            VStack(alignment: .leading, spacing: 17) {
                Text("THE SIGNING PIPELINE").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(Studio.muted)
                ForEach(Array(pipeline.enumerated()), id: \.element) { index, stage in
                    pipelineRow(stage, index: index)
                }
                Text("Credentials and compatibility are validated during the signing operation.")
                    .font(.system(size: 10)).foregroundStyle(Studio.muted).lineSpacing(3).padding(.top, 2)
            }
        }
    }

    private func pipelineRow(_ stage: SigningStage, index: Int) -> some View {
        let currentIndex = model.currentJob?.events.compactMap { pipeline.firstIndex(of: $0.stage) }.max() ?? -1
        let completed = currentIndex > index || model.currentJob?.status == .completed
        let active = model.isRunning && currentIndex == index
        let skipped = stage == .injecting && (model.currentJob?.injectionNames.isEmpty ?? model.injections.isEmpty)
        return HStack(spacing: 11) {
            ZStack {
                Circle().fill(completed || active ? Studio.mint.opacity(0.10) : Studio.raised).frame(width: 22, height: 22)
                if skipped {
                    Image(systemName: "minus").font(.system(size: 8, weight: .bold)).foregroundStyle(Studio.muted)
                } else if completed {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Studio.mint)
                } else if active {
                    Circle().fill(Studio.mint).frame(width: 6, height: 6)
                } else {
                    Text(String(format: "%02d", index + 1)).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(Studio.muted)
                }
            }
            Text(skipped ? "No libraries to inject" : stage.title).font(.system(size: 11, weight: active ? .semibold : .regular)).foregroundStyle(!skipped && (active || completed) ? .white.opacity(0.9) : Studio.muted)
            Spacer()
            if active { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12) }
        }
    }
}
