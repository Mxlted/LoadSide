import SwiftUI
import LoadSideCore

struct SigningProfilesView: View {
    @ObservedObject var model: WorkspaceModel
    @State private var showSave = false
    @State private var renaming: SavedSigningProfile?
    @State private var deleting: SavedSigningProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 20) {
                PageHeading(title: "Signing Profiles", detail: "Keep your certificate and provisioning profiles ready for the next app.")
                Spacer()
                Button { showSave = true } label: { Label("Save Current Identity…", systemImage: "plus") }
                    .adaptiveGlassButton(prominent: true).disabled(!model.canSaveSigningProfile)
                    .help(model.canSaveSigningProfile ? "Save the signing identity currently loaded in the workspace" : "Import a certificate and provisioning profiles in the workspace first")
            }
            if let notice = model.savedProfileNotice { InlineNotice(message: notice, color: Palette.accent, symbol: "info.circle") }
            if model.isManagingSigningProfiles { ProgressView("Updating profile library…").controlSize(.small).font(.system(size: 12)) }
            if model.savedSigningProfiles.isEmpty {
                VStack(spacing: 0) {
                    EmptyState(symbol: "person.crop.rectangle.stack", title: "No saved signing profiles", description: "Import a P12 and provisioning profiles in the workspace, then save the identity. You can choose whether to remember its password in Keychain.")
                    Button("Open Workspace") { model.jobMode = .sign; model.section = .workspace }.adaptiveGlassButton(prominent: true).padding(.bottom, 44)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 506), spacing: 15, alignment: .top)], spacing: 15) {
                        ForEach(model.savedSigningProfiles) { profile in profileRow(profile) }
                    }
                }
                Label("Saved copies stay on this Mac. Passwords are remembered in Keychain only when you choose.", systemImage: "lock.shield")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(AppMetrics.pagePadding)
        .sheet(isPresented: $showSave) { SaveSigningProfileSheet(model: model) }
        .sheet(item: $renaming) { profile in RenameSigningProfileSheet(model: model, profile: profile) }
        .alert("Delete signing profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let profile = deleting { Task { await model.deleteSigningProfile(profile.id) } }
                deleting = nil
            }
        } message: {
            Text("Delete “\(deleting?.name ?? "")” and its saved file copies and remembered password. Original imported files are preserved. If this profile is selected, its signing inputs will be cleared.")
        }
    }

    private func profileRow(_ profile: SavedSigningProfile) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .center, spacing: 13) {
                    SymbolTile(symbol: "person.crop.rectangle", size: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 9) {
                            Text(profile.name).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                            if model.selectedSigningProfileID == profile.id {
                                Label("Selected", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(profile.profileCount) provisioning profile\(profile.profileCount == 1 ? "" : "s")")
                            Label(profile.remembersPassword ? "Password in Keychain" : "Password not saved", systemImage: profile.remembersPassword ? "lock.fill" : "lock.open")
                        }.font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 11)
                    Button(model.selectedSigningProfileID == profile.id ? "Open" : "Use Profile") {
                        Task {
                            await model.selectSigningProfile(profile.id)
                            if model.selectedSigningProfileID == profile.id { model.jobMode = .sign; model.section = .workspace }
                        }
                    }.disabled(model.isRunning || model.isManagingSigningProfiles || profile.issue != nil)
                    Menu {
                        Button("Rename…") { renaming = profile }
                        Button("Delete…", role: .destructive) { deleting = profile }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: AppMetrics.iconButtonSize, height: AppMetrics.iconButtonSize).help("Actions for \(profile.name)").accessibilityLabel("Actions for \(profile.name)")
                    .disabled(model.isRunning || model.isManagingSigningProfiles)
                }
                HStack(spacing: 18) {
                    Text("Saved \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    Text("Earliest expiry \(profile.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                        .foregroundStyle(profile.expiresAt <= Date() ? Palette.warning : Color.secondary)
                }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 62)
                if let issue = profile.issue { InlineNotice(message: issue, color: Palette.error) }
            }
        }
    }
}

struct SaveSigningProfileSheet: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var rememberPassword = false
    @State private var attemptedSave = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save signing profile").font(.system(size: 20, weight: .semibold))
                Text("Reuse this certificate and its provisioning profiles.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            TextField("Profile name", text: $name).inputField().focused($nameFocused).accessibilityLabel("Signing profile name")
            Panel(padding: 13) {
                VStack(alignment: .leading, spacing: 9) {
                    if let certificate = model.certificate { FileRow(url: certificate, symbol: "key.horizontal") }
                    Text("\(model.profiles.count) provisioning profile\(model.profiles.count == 1 ? "" : "s") will be copied with the certificate.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Remember P12 password in Keychain", isOn: $rememberPassword).toggleStyle(.checkbox).font(.system(size: 13))
                Text(rememberPassword ? "The current password will be stored as a local Keychain password item. The signing identity is never imported into your login keychain." : "The password will not be saved. Enter it again when you use this signing profile.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if attemptedSave, let notice = model.savedProfileNotice { InlineNotice(message: notice, color: Palette.error) }
            Divider()
            HStack {
                if model.isManagingSigningProfiles { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isManagingSigningProfiles)
                Button("Save Profile") {
                    attemptedSave = true
                    let previousIDs = Set(model.savedSigningProfiles.map(\.id))
                    Task {
                        await model.saveSigningProfile(name: name, rememberPassword: rememberPassword)
                        if model.savedSigningProfiles.contains(where: { !previousIDs.contains($0.id) }) { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canSaveSigningProfile)
            }
        }.padding(31).frame(width: 517)
        .interactiveDismissDisabled(model.isManagingSigningProfiles)
        .onAppear { nameFocused = true }
    }
}

private struct RenameSigningProfileSheet: View {
    @ObservedObject var model: WorkspaceModel
    let profile: SavedSigningProfile
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var attemptedSave = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rename signing profile").font(.system(size: 20, weight: .semibold))
            TextField("Profile name", text: $name).inputField().accessibilityLabel("Signing profile name")
            if attemptedSave, let notice = model.savedProfileNotice { InlineNotice(message: notice, color: Palette.error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isManagingSigningProfiles)
                Button("Rename") {
                    attemptedSave = true
                    Task {
                        await model.renameSigningProfile(profile.id, name: name)
                        if model.savedSigningProfiles.first(where: { $0.id == profile.id })?.name == name.trimmingCharacters(in: .whitespacesAndNewlines) { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isManagingSigningProfiles)
            }
        }.padding(26).frame(width: 429).onAppear { name = profile.name }
        .interactiveDismissDisabled(model.isManagingSigningProfiles)
    }
}
