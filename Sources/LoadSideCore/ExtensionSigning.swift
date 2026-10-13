import Foundation

struct BundleProfileSelection {
    let profile: ProvisioningProfile
    let usesProfileIdentity: Bool
}

extension ProvisioningProfile {
    /// Profile-only eligibility, not a certificate or device eligibility verdict.
    public func canReuseIdentity(forExtension identifier: String, mainBundleIdentifier: String) -> Bool {
        !bundleIdentifierPattern.contains("*")
            && identifier.hasPrefix(mainBundleIdentifier + ".")
    }

    static func selectForBundle(from profiles: [ProvisioningProfile], bundleIdentifier: String,
                                certificate: Data, mainProfile: ProvisioningProfile,
                                mainBundleIdentifier: String, isExtension: Bool,
                                policy: ExtensionProfilePolicy) throws -> BundleProfileSelection {
        do {
            return BundleProfileSelection(profile: try select(from: profiles, bundleIdentifier: bundleIdentifier, certificate: certificate), usesProfileIdentity: false)
        } catch let error as LoadSideError where error.code == "profile.noMatch" {
            // Never hide ambiguous matches or replace a supplied matching profile
            // whose certificate is incompatible. Nested .app bundles cannot opt in.
            guard policy == .reuseMain, isExtension,
                  !profiles.contains(where: { $0.matches(bundleIdentifier: bundleIdentifier) }),
                  mainProfile.developerCertificates.contains(certificate),
                  mainProfile.canReuseIdentity(forExtension: bundleIdentifier, mainBundleIdentifier: mainBundleIdentifier) else { throw error }
            return BundleProfileSelection(profile: mainProfile, usesProfileIdentity: true)
        }
    }
}
