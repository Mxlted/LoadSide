import SwiftUI

struct GuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LoadSide Help").font(.system(size: 20, weight: .semibold))
                    Text("Sign a decrypted IPA using your own certificate and provisioning profiles.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                helpSection("Signing an app", symbol: "signature", entries: [
                    ("Choose the IPA", "Open or drop a decrypted app archive. LoadSide inspects its bundle identifier and extensions before signing. It does not remove FairPlay encryption."),
                    ("Choose the identity", "Import a P12 with a usable private key and Apple signing certificate, enter its password, and add matching mobileprovision files. Each retained extension and nested app needs a matching profile."),
                    ("Review the plan", "Automatic keeps an authorized original ID or selects the unique exact app ID from your profiles. The proposed change is shown before signing. Keep original requires that the current ID is authorized; an explicit override takes precedence over either mode."),
                    ("Sign and export", "Choose a new output location. LoadSide validates credentials and entitlements, signs nested code from the inside out, verifies the result, then writes the IPA. Original inputs remain unchanged.")
                ])
                helpSection("Saving signing profiles", symbol: "person.crop.rectangle.stack", entries: [
                    ("Save once, reuse later", "A saved signing profile groups a private copy of your P12 with its provisioning profiles. Give it a recognizable name, then choose it from the saved-profile menu when signing another app. Profiles are checked again when selected."),
                    ("Remembering passwords is optional", "Remember password is off by default. When enabled, only the P12 password is stored as a local Keychain password item. Signing identities use a separate temporary keychain for each export. Passwords never appear in job history or diagnostics."),
                    ("Manage saved profiles", "Use Signing Profiles to select, rename, or delete an identity. Deletion removes saved copies and the remembered password, preserves your original imported files, and clears the signing inputs when that profile was selected.")
                ])
                helpSection("Identifiers, extensions, and capabilities", symbol: "checkmark.seal", entries: [
                    ("An identifier change has consequences", "A profile authorizes a particular application ID and team. Changing the ID can affect keychain access, app groups, push services, and extension relationships. A preflight suggestion checks app-ID authorization; certificate membership is validated during signing."),
                    ("Extensions are never removed automatically", "The signing plan shows how many extensions are present and which identifiers have no supplied matching profile. Add the missing profiles or explicitly remove all extensions. Removing them disables their features, such as widgets, sharing actions, and notification extensions. Nested apps still need matching profiles."),
                    ("Strict is the default", "Strict stops if a requested entitlement is unsupported. Compatible explicitly allows unsupported entitlements to be removed and records every removal. Related capabilities may no longer work. Automatic identifier selection never changes this policy."),
                    ("Profiles determine installation eligibility", "A profile controls certificate membership, app IDs, capabilities, devices, expiry, and distribution. App Store profiles cannot be used for direct installation. Offline validation does not check certificate revocation or prove that an app installs or launches.")
                ])
                helpSection("Injecting libraries", symbol: "puzzlepiece.extension", entries: [
                    ("Supported inputs", "Add DEB packages, dylibs, or frameworks. DEBs are read as data; maintainer scripts are never executed. Supported libraries, frameworks, and resources are staged, load commands are updated, and all injected code is re-signed."),
                    ("DEB layout and filters", "MobileSubstrate entry-point filters must target the app. Rootful and /var/jb layouts are supported with usr/lib dependencies, Library/Frameworks content, and adjacent resource bundles. Runtime class filters and library-only DEBs require explicit supported library inputs."),
                    ("Signing does not guarantee runtime compatibility", "A tweak may require a hooking framework, privileged APIs, or paths unavailable on an unmodified device. Supply compatible dependencies. Missing dependencies, incompatible architectures, and insufficient Mach-O header space produce a diagnostic error.")
                ])
                helpSection("Troubleshooting", symbol: "stethoscope", entries: [
                    ("Cancel or retry", "Cancel stops the current operation and cleans temporary work. After a failure, correct the inputs, re-enter the password if needed, and export again. The output is written only after verification succeeds."),
                    ("Inspect Activity", "Each job records the engine’s events, any errors, and verified export details including a SHA-256 hash. Save Diagnostics exports the record. Reports can include paths, profile details, and certificate names; review them before sharing."),
                    ("Install separately", "LoadSide exports signed IPAs. Device installation, Apple ID provisioning, certificate renewal, and decryption are outside this workflow. Use an installation tool and a device eligible under the provisioning profile.")
                ])
            }.padding(24).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func helpSection(_ title: String, symbol: String, entries: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
            Panel {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries.indices, id: \.self) { index in
                        DisclosureGroup(entries[index].0) {
                            Text(entries[index].1).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.bottom, 4)
                        }.font(.system(size: 12)).padding(.vertical, 8)
                        if index < entries.count - 1 { Divider() }
                    }
                }
            }
        }
    }
}
