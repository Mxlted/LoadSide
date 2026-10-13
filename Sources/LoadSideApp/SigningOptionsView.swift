import LoadSideCore
import SwiftUI

/// Signing disclosures share persistent presentation preferences across workflows and launches.
struct SigningOptionsView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var disclosures: DisclosurePreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "Signing options")
            Panel(padding: 15) {
                VStack(alignment: .leading, spacing: 13) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Bundle identifier").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Picker("Bundle identifier policy", selection: $model.identifierPolicy) {
                            Text("Keep original").tag(BundleIdentifierPolicy.preserve)
                            Text("Automatic").tag(BundleIdentifierPolicy.automatic)
                        }.pickerStyle(.segmented).labelsHidden()
                        if let suggestion = model.identifierSuggestion {
                            Text(suggestion.effectiveIdentifier).font(.system(size: 13, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                            if suggestion.usesProfileIdentity {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("Profile signing ID:").foregroundStyle(.secondary)
                                    Text(suggestion.profileBundleIdentifier).font(.system(size: 12, design: .monospaced)).textSelection(
                                        .enabled)
                                }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                                InlineNotice(
                                    message:
                                        "Keeps the app’s original bundle ID and uses your profile’s identity in the signature. This compatibility mode may affect keychain access and app services; device behavior is unverified.",
                                    color: Palette.warning, symbol: "exclamationmark.triangle")
                            } else if suggestion.changesIdentifier {
                                Text("Changed from \(suggestion.originalIdentifier)").font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                                InlineNotice(message: suggestion.reason, color: Palette.accent, symbol: "arrow.triangle.2.circlepath")
                            } else {
                                Text(suggestion.reason).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                                    horizontal: false, vertical: true)
                            }
                        } else {
                            Text(
                                model.identifierPolicy == .automatic
                                    ? "Uses an unambiguous profile ID only if the original ID is not authorized."
                                    : "Keeps the app’s original bundle ID. When needed, the signature uses your profile’s exact app identity."
                            )
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let error = model.identifierSuggestionError {
                            InlineNotice(message: error, color: Palette.error)
                            if let recovery = model.identifierSuggestionRecovery {
                                Text(recovery).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        if model.identifierSuggestion != nil {
                            Text("Certificate authorization is verified when signing starts.")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    Divider()
                    DisclosureGroup(isExpanded: disclosures.binding(.extensions)) {
                        extensionPlan.padding(.top, 11)
                    } label: {
                        optionSummary(
                            "Extensions",
                            value: model.removeExtensions
                                ? "Remove from export"
                                : model.extensionProfilePolicy == .reuseMain ? "Reuse main · experimental" : "Matching profiles",
                            warning: model.removeExtensions || model.extensionProfilePolicy == .reuseMain)
                    }
                    .font(.system(size: 13))
                    if !disclosures.isExpanded(.extensions), !model.blockingExtensionIdentifiers.isEmpty, !model.removeExtensions {
                        InlineNotice(
                            message: "\(model.blockingExtensionIdentifiers.count) extension(s) need profiles. Open Extensions to review.")
                    }
                    if !disclosures.isExpanded(.extensions), !model.compatibilityExtensionIdentifiers.isEmpty, !model.removeExtensions {
                        Text(
                            "\(model.compatibilityExtensionIdentifiers.count) extension(s) will share the main signing identity. Device behavior is unverified."
                        )
                        .font(.system(size: 12)).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
                    }
                    if !disclosures.isExpanded(.extensions), !model.unmatchedNestedAppIdentifiers.isEmpty {
                        InlineNotice(message: "Nested apps need matching profiles. Open Extensions to review.")
                    }
                    Divider()
                    DisclosureGroup(isExpanded: disclosures.binding(.entitlements)) {
                        VStack(alignment: .leading, spacing: 9) {
                            Picker("Entitlement policy", selection: $model.policy) {
                                Text("Strict").tag(EntitlementPolicy.strict)
                                Text("Compatible").tag(EntitlementPolicy.compatible)
                            }.pickerStyle(.segmented).labelsHidden()
                            Text(
                                model.policy == .strict
                                    ? "Keeps authorized capabilities; stops when others cannot be preserved. Unapproved Apple-restricted entitlements are omitted and logged."
                                    : "Removes unsupported capabilities and records each change. Push notifications, app groups, or other features may stop working."
                            )
                            .font(.system(size: 12)).foregroundStyle(model.policy == .strict ? Color.secondary : Palette.warning).fixedSize(
                                horizontal: false, vertical: true)
                        }.padding(.top, 11)
                    } label: {
                        optionSummary(
                            "Entitlements", value: model.policy == .strict ? "Strict" : "Compatible · may remove features",
                            warning: model.policy == .compatible)
                    }
                    .font(.system(size: 13))
                    Divider()
                    DisclosureGroup("App overrides", isExpanded: $model.showAdvanced) {
                        VStack(alignment: .leading, spacing: 11) {
                            TextField("Bundle ID (optional)", text: $model.bundleIdentifier).inputField().accessibilityLabel(
                                "Explicit bundle identifier override")
                            Text("An explicit ID overrides the selection above and must be authorized by a supplied profile.").font(
                                .system(size: 12)
                            ).foregroundStyle(.secondary)
                            TextField("Display name (optional)", text: $model.displayName).inputField().accessibilityLabel(
                                "App display name override")
                        }.padding(.top, 9)
                    }.font(.system(size: 12, weight: .medium))
                }
            }
        }
        .disabled(model.isRunning)
    }

    private func optionSummary(_ title: String, value: String, warning: Bool = false) -> some View {
        HStack(spacing: 9) {
            Text(title).fontWeight(.medium)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 12)).foregroundStyle(warning ? Palette.warning : Color.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var extensionPlan: some View {
        VStack(alignment: .leading, spacing: 11) {
            let count = model.ipaInspection?.extensionCount ?? 0
            HStack {
                Text("Extension profiles").font(.system(size: 13, weight: .medium))
                Spacer()
                if model.ipaInspection != nil {
                    Text("\(count) found").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 11) {
                extensionChoice(.reuseMain, title: "Reuse main profile (experimental)")
                extensionChoice(.matching, title: "Require matching profiles")
            }
            .disabled(model.removeExtensions)
            if !model.removeExtensions {
                if model.extensionProfilePolicy == .reuseMain {
                    Text("Uses matching profiles when available, then reuses the main profile for eligible extensions.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Experimental compatibility", isExpanded: disclosures.binding(.compatibility)) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(
                                "Extensions keep their bundle IDs but may share the main app’s signing identity and keychain access. File importing, app groups, and other features may fail. Device behavior is unverified."
                            )
                            if !model.compatibilityExtensionIdentifiers.isEmpty {
                                Text("Using shared identity: \(model.compatibilityExtensionIdentifiers.joined(separator: ", "))")
                                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            }
                        }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 7)
                    }.font(.system(size: 12)).foregroundStyle(Palette.warning)
                } else {
                    Text("Each extension needs an authorized profile. A matching wildcard profile can cover more than one bundle.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !model.blockingExtensionIdentifiers.isEmpty {
                    InlineNotice(message: "Add matching profiles for \(model.blockingExtensionIdentifiers.count) extension(s) to continue.")
                    ForEach(model.blockingExtensionIdentifiers, id: \.self) { identifier in
                        Text(identifier).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                    Button("Add extension profiles…", action: model.chooseProfiles).controlSize(.regular)
                }
            }
            if count > 0 || model.removeExtensions {
                Divider().padding(.vertical, 2)
                Toggle("Remove app extensions", isOn: $model.removeExtensions).toggleStyle(.checkbox).font(.system(size: 13))
                if model.removeExtensions {
                    Text("The export will lose extension features such as widgets, share actions, and notification services.")
                        .font(.system(size: 12)).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("View extension identifiers", isExpanded: disclosures.binding(.extensionIdentifiers)) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.ipaInspection?.extensionBundleIdentifiers ?? [], id: \.self) { identifier in
                            let effective = model.identifierSuggestion?.identifier(forOriginalBundleIdentifier: identifier) ?? identifier
                            HStack(alignment: .top, spacing: 7) {
                                if model.unmatchedExtensionIdentifiers.contains(effective) && !model.removeExtensions {
                                    Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.warning)
                                        .help(
                                            model.compatibilityExtensionIdentifiers.contains(effective)
                                                ? "Will reuse the main profile’s identity" : "Needs a matching profile")
                                }
                                Text(effective).textSelection(.enabled)
                            }.font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 12))
            } else if model.ipaInspection != nil {
                Text("This app has no extensions.").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            if !model.unmatchedNestedAppIdentifiers.isEmpty {
                InlineNotice(
                    message:
                        "Nested apps need matching profiles: \(model.unmatchedNestedAppIdentifiers.joined(separator: ", ")). Main-profile reuse applies only to extensions."
                )
            }
        }
    }

    private func extensionChoice(_ policy: ExtensionProfilePolicy, title: String) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { model.extensionProfilePolicy == policy },
                set: { model.selectExtensionProfilePolicy(policy, isSelected: $0) }
            )
        )
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
        .accessibilityIdentifier("extension-policy.\(policy.rawValue)")
        .accessibilityHint("Choose one extension profile policy. Selecting this option replaces the other selection.")
    }

}
