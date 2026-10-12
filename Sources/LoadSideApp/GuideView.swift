import SwiftUI

struct GuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Know what you’re signing.").font(.system(size: 29, weight: .semibold)).tracking(-0.8)
                    Text("A practical guide to certificates, app capabilities, and reliable exports.").font(.system(size: 12)).foregroundStyle(Studio.muted)
                }
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 20) {
                        guideCard("01", "A complete signing session", symbol: "checklist", entries: [
                            ("Add a decrypted IPA", "Use an app you own or are authorized to modify. LoadSide checks the archive and Mach-O binaries. It does not remove FairPlay encryption."),
                            ("Bring your signing identity", "Your P12 must contain a usable private key and Apple signing certificate. Add the matching mobileprovision files, including profiles for app extensions and nested apps."),
                            ("Choose an export destination", "LoadSide uses a private temporary workspace, validates inputs, prepares entitlements, signs code from the inside out, and verifies signatures before exporting.")
                        ])
                        guideCard("02", "Profiles & entitlements", symbol: "checkmark.seal", entries: [
                            ("Profiles authorize capabilities", "A provisioning profile controls the team, application identifier, certificate, devices, expiry date, and permitted entitlements. A valid signature alone does not make an app eligible for installation."),
                            ("Strict is the default", "Signing stops when a requested entitlement is not allowed. Compatible mode can remove unsupported entitlements, but affected capabilities may no longer work."),
                            ("Changing bundle identifiers", "A new identifier must be authorized by a supplied profile. Keychain groups, app groups, push services, associated domains, and extension relationships need particular care."),
                            ("Deliberately removing extensions", "If you only have a main-app profile, enable Remove app extensions in Signing options to exclude all .appex bundles from the export. This is off by default. Safari extensions, widgets, share actions, and other extension features will no longer be available. Nested apps still require matching profiles. Your source IPA is preserved, and each removal is recorded in diagnostics.")
                        ])
                    }.frame(maxWidth: .infinity)
                    VStack(spacing: 20) {
                        guideCard("03", "Injecting libraries", symbol: "puzzlepiece.extension", entries: [
                            ("DEB, dylib & framework", "DEB packages are unpacked as data. Package scripts are never run. Supported payloads are embedded and executable load commands are updated before all injected code is re-signed."),
                            ("Supported DEB layout", "MobileSubstrate entry-point filters must target the app. Rootful and /var/jb package layouts are supported, with usr/lib dependencies, Library/Frameworks content, and adjacent resource bundles. Runtime class filters and library-only DEBs need explicit supported library inputs."),
                            ("Runtime compatibility matters", "A jailbreak tweak may rely on a hooking framework, privileged APIs, or unavailable paths. Supply compatible dependencies. Successful signing cannot guarantee that a tweak will run on an unmodified device."),
                            ("Inspect the diagnostics", "Unsupported archive content, incompatible architectures, missing dependencies, or insufficient Mach-O space cause an actionable error instead of an incomplete export.")
                        ])
                        guideCard("04", "Recovery & privacy", symbol: "lock.shield", entries: [
                            ("Nothing is uploaded", "The app, certificate, profile, and signing operation remain on this Mac. Certificate passwords are not saved and are cleared from the input field when signing starts."),
                            ("Cancel and retry", "Cancellation stops the operation and cleans the working directory. Correct the inputs, re-enter the P12 password, and start another export. Your original files are preserved."),
                            ("Use Activity for evidence", "Each session records pipeline events, errors, and successful export details. Save diagnostics when troubleshooting. Reports can include file names, export paths, and signing identity, so review them before sharing.")
                        ])
                    }.frame(maxWidth: .infinity)
                }
                StudioCard {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "iphone.and.arrow.forward").font(.system(size: 23, weight: .light)).foregroundStyle(Studio.mint)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Export first. Install with your preferred tool.").font(.system(size: 14, weight: .semibold))
                            Text("LoadSide produces signed IPA files. Device installation, Apple ID provisioning, certificate renewal, and decryption are outside this workflow. Your device must satisfy the profile’s distribution and registration requirements. Offline validation does not check certificate revocation or prove that an app will install or launch on a device.")
                                .font(.system(size: 12)).foregroundStyle(Studio.muted).lineSpacing(4)
                        }
                    }
                }
            }.padding(30)
        }.scrollIndicators(.hidden)
    }

    private func guideCard(_ number: String, _ title: String, symbol: String, entries: [(String, String)]) -> some View {
        StudioCard {
            VStack(alignment: .leading, spacing: 21) {
                HStack {
                    CardHeading(number: number, title: title)
                    Image(systemName: symbol).foregroundStyle(Studio.mint).font(.system(size: 17))
                }
                ForEach(entries.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(entries[index].0).font(.system(size: 12, weight: .semibold))
                        Text(entries[index].1).font(.system(size: 11)).foregroundStyle(Studio.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
