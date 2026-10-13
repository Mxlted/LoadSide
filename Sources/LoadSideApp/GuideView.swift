import SwiftUI

struct GuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(title: "LoadSide Help", detail: "Prepare, sign, and share apps from your Mac.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 385), spacing: 22, alignment: .top)], alignment: .leading, spacing: 24) {
                helpSection("Signing an app", symbol: "signature", entries: [
                    ("Choose the IPA", "Open or drop a decrypted app archive. LoadSide inspects its bundle identifier and extensions before signing. It does not remove FairPlay encryption."),
                    ("Choose the identity", "Import a P12 with a usable private key and Apple signing certificate, enter its password, and add a mobileprovision that authorizes the app. Matching profiles are preferred for extensions; experimental main-profile reuse is selected by default when a matching extension profile is missing. Nested apps always need matching profiles."),
                    ("Review the plan", "Keep original is selected by default: LoadSide preserves the app’s bundle ID. If it differs from your profile, LoadSide can keep that ID in the app’s metadata while using one unambiguous exact profile identity in the signature. The plan shows both IDs and a compatibility warning. Automatic can change the app’s bundle ID to match the profile. An explicit bundle ID override takes precedence and must be authorized by a profile."),
                    ("Sign and export", "Choose a new output location. LoadSide validates credentials and entitlements, signs nested code from the inside out, verifies the result, then writes the IPA. Original inputs remain unchanged.")
                ])
                helpSection("Saving signing profiles", symbol: "person.crop.rectangle.stack", entries: [
                    ("Save once, reuse later", "A saved signing profile groups a private copy of your P12 with its provisioning profiles. Give it a recognizable name, then choose it from the saved-profile menu when signing another app. Profiles are checked again when selected."),
                    ("Remembering passwords is optional", "Remember password is off by default. When enabled, only the P12 password is stored as a local Keychain password item. Signing identities use a separate temporary keychain for each export. Passwords never appear in job history or diagnostics."),
                    ("Manage saved profiles", "Use Signing Profiles to select, rename, or delete an identity. Deletion removes saved copies and the remembered password, preserves your original imported files, and clears the signing inputs when that profile was selected.")
                ])
                helpSection("Identifiers, extensions, and capabilities", symbol: "checkmark.seal", entries: [
                    ("Bundle ID and signing identity", "The app’s metadata bundle ID and its signed application-identifier can differ in Keep original compatibility mode. LoadSide uses the profile’s authorized identity in signed entitlements while retaining the original metadata ID. This follows SignTools’ supplied-profile approach and does not authorize arbitrary capabilities. A mismatch can affect keychain access, app services and installation; device behavior is unverified. Preflight uses profile metadata, and the engine checks certificate membership during signing."),
                    ("Keep app extensions", "The extension-profile checkboxes select one policy at a time. Reuse main profile is selected by default; Require matching profiles gives every extension its own authorized identity. A matching wildcard profile can cover several bundles when it authorizes their capabilities. Add profiles using the identifiers in the signing plan. Extension removal is a separate, explicit choice and disables extension features. Nested apps always need matching profiles."),
                    ("Strict is the default", "Documented entitlements requiring Apple approval are omitted and logged when the profile does not authorize them, in either mode. This includes CarPlay, payment and identity services, alternative browsers, research APIs and other managed capabilities. Distribution-only approval exceptions do not apply to development profiles. Authorized claims are preserved. Strict stops for other unsupported capabilities; Compatible allows their removal too. Related features may no longer work. Unknown entitlements are not assumed to require approval."),
                    ("Experimental extension compatibility", "Reuse main profile retains unmatched extensions with their distinct bundle IDs but signs them using the main profile’s exact application-identifier. This default follows the compatibility approach used by SignTools. It only applies to extensions beneath the main app’s ID and prefers matching profiles whenever supplied. Shared signing identity may share keychain access and break file importing, app groups, or other features. Certificate membership, expiry, platforms, devices and entitlement checks still apply. Compatible entitlements is a separate explicit choice. Local signature verification does not prove installation or extension functionality."),
                    ("Profiles determine installation eligibility", "A profile controls certificate membership, app IDs, capabilities, devices, expiry, and distribution. App Store profiles cannot be used for direct installation. Offline validation does not check certificate revocation or prove that an app installs or launches.")
                ])
                helpSection("Injecting libraries", symbol: "puzzlepiece.extension", entries: [
                    ("Inject without a certificate", "Select Inject only in the workspace, choose a decrypted IPA, and add a DEB, dylib, or framework. No P12 or provisioning profile is needed. LoadSide patches a private copy, removes existing signatures, validates the injected code, and exports an unsigned IPA. Sign it with LoadSide or another signing tool before installing. Unsigned exports are not added to the signed app library."),
                    ("Supported inputs", "Add DEB packages, dylibs, or frameworks. DEBs are read as data; maintainer scripts are never executed. Supported libraries, frameworks, and resources are staged and load commands are updated. Sign & export also signs all injected code; Inject only leaves the export unsigned."),
                    ("DEB layout and filters", "MobileSubstrate entry-point filters must target the app. Rootful and /var/jb layouts are supported with usr/lib dependencies, Library/Frameworks content, and adjacent resource bundles. Runtime class filters and library-only DEBs require explicit supported library inputs."),
                    ("Signing does not guarantee runtime compatibility", "A tweak may require a hooking framework, privileged APIs, or paths unavailable on an unmodified device. Supply compatible dependencies. Missing dependencies, incompatible architectures, and insufficient Mach-O header space produce a diagnostic error.")
                ])
                helpSection("Local app library", symbol: "network", entries: [
                    ("Find signed exports", "Successfully signed apps are copied into Local Library automatically. Use the library menu to add previous completed signing exports from Activity. Show Folder opens the private library directory. Removing a library copy keeps the original exported IPA."),
                    ("Share on your network", "Open Local Library and choose Start Sharing. Automatic HTTPS creates a temporary internet-accessible link; Local downloads only restricts access to your network. Keep LoadSide open. Anyone with the link can download the library; share it only with trusted people. Stop Sharing invalidates the session’s links and closes the HTTPS connection."),
                    ("Enable installation links", "Leave Automatic HTTPS selected, then Start Sharing. On first use, LoadSide downloads and verifies the official Cloudflare helper. It creates a temporary HTTPS address without an account or domain, following SignTools’ tunnel approach. App downloads pass through Cloudflare; signing credentials stay on your Mac. Scan the QR code and open the catalog in Safari, then tap Install on device. You can also select My HTTPS server for your own reverse proxy. Your device must be eligible under the app’s provisioning profile; local verification does not guarantee installation or launch.")
                ])
                helpSection("Troubleshooting", symbol: "stethoscope", entries: [
                    ("Cancel or retry", "Cancel stops the current operation and cleans temporary work. After a failure, correct the inputs, re-enter the password if needed, and export again. The output is written only after verification succeeds."),
                    ("Inspect Activity", "Each job records the engine’s events, any errors, and verified export details including a SHA-256 hash. Save Diagnostics exports the record. Reports can include paths, profile details, and certificate names; review them before sharing."),
                    ("Installation requirements", "Use Local Library with a trusted HTTPS address for browser install links, or install a signed IPA with another installation tool. Unsigned injected IPAs must be signed first. Apple ID provisioning, certificate renewal, and decryption are outside this workflow.")
                ])
                }
            }.padding(AppMetrics.pagePadding).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func helpSection(_ title: String, symbol: String, entries: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.system(size: 15, weight: .semibold))
                .labelStyle(.titleAndIcon)
            Panel(padding: 15) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries.indices, id: \.self) { index in
                        DisclosureGroup(entries[index].0) {
                            Text(entries[index].1).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 9).padding(.bottom, 4)
                        }.font(.system(size: 14, weight: .medium))
                            .disclosureGroupStyle(FullRowDisclosureStyle(headerVerticalPadding: 16))
                        if index < entries.count - 1 { Divider() }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
