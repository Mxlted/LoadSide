import CryptoKit
import Foundation
import Security

/// A profile whose CMS signature, Apple root chain, and validity dates have been checked.
/// This does not establish current revocation status or authorize an unlisted device.
public struct ProvisioningProfile: @unchecked Sendable {
    public let url: URL
    public let uuid: String
    public let name: String
    public let teamIdentifier: String
    public let applicationIdentifier: String
    public let expiresAt: Date
    public let deviceCount: Int
    public let provisionsAllDevices: Bool
    public let platforms: [String]
    public var bundleIdentifierPattern: String { String(applicationIdentifier.dropFirst(appIdentifierPrefix.count + 1)) }
    public var distribution: String {
        provisionsAllDevices
            ? "Enterprise"
            : (deviceCount > 0 ? ((entitlements["get-task-allow"] as? Bool == true) ? "Development" : "Ad Hoc") : "App Store")
    }
    let entitlements: [String: Any]
    let developerCertificates: [Data]
    let data: Data
    var appIdentifierPrefix: String { String(applicationIdentifier.prefix { $0 != "." }) }

    public static func inspect(_ url: URL) throws -> ProvisioningProfile {
        let data = try BoundedFile.read(
            url, maximumBytes: 16 * 1_024 * 1_024,
            invalid: LoadSideError("profile.size", "The provisioning profile must be a regular file no larger than 16 MiB."))
        return try ProvisioningProfile(url: url, payload: decodeVerifiedCMS(data), data: data)
    }

    init(url: URL, payload: Data, data: Data, now: Date = Date()) throws {
        guard let dict = try PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
            let uuid = dict["UUID"] as? String, let name = dict["Name"] as? String,
            let teams = dict["TeamIdentifier"] as? [String], let team = teams.first, teams.count == 1,
            let entitlements = dict["Entitlements"] as? [String: Any],
            let appID = entitlements["application-identifier"] as? String,
            let expiration = dict["ExpirationDate"] as? Date,
            let creation = dict["CreationDate"] as? Date,
            let certificates = dict["DeveloperCertificates"] as? [Data], !certificates.isEmpty,
            let prefixes = dict["ApplicationIdentifierPrefix"] as? [String],
            prefixes.contains(String(appID.prefix { $0 != "." })),
            entitlements["com.apple.developer.team-identifier"] as? String == team
        else {
            throw LoadSideError(
                "profile.malformed", "The provisioning profile is missing required identity, entitlement, or certificate fields.")
        }
        guard expiration > now else {
            throw LoadSideError(
                "profile.expired", "Provisioning profile “\(name)” has expired.",
                recovery: "Download a current profile from your Apple Developer account.")
        }
        guard creation <= now.addingTimeInterval(300) else {
            throw LoadSideError(
                "profile.future", "Provisioning profile “\(name)” is not valid yet.",
                recovery: "Check your Mac’s clock and the profile creation date.")
        }
        guard appID.contains("."), !team.isEmpty else {
            throw LoadSideError("profile.appID", "The profile has an invalid application identifier.")
        }
        if let platforms = dict["Platform"] as? [String],
            !platforms.contains(where: { ["iOS", "tvOS", "watchOS", "visionOS", "xrOS"].contains($0) })
        {
            throw LoadSideError("profile.platform", "This provisioning profile does not target an IPA platform.")
        }
        self.url = url
        self.uuid = uuid
        self.name = name
        self.teamIdentifier = team
        self.applicationIdentifier = appID
        self.expiresAt = expiration
        self.entitlements = entitlements
        self.developerCertificates = certificates
        self.data = data
        self.deviceCount = (dict["ProvisionedDevices"] as? [String])?.count ?? 0
        self.provisionsAllDevices = dict["ProvisionsAllDevices"] as? Bool ?? false
        self.platforms = dict["Platform"] as? [String] ?? []
    }

    /// Tests the profile's App ID pattern only; this does not validate a signing certificate.
    public func matches(bundleIdentifier: String) -> Bool {
        EntitlementResolver.matches("\(appIdentifierPrefix).\(bundleIdentifier)", allowed: applicationIdentifier)
    }

    func supports(machOPlatform: UInt32) -> Bool {
        let accepted: [UInt32: Set<String>] = [2: ["iOS"], 3: ["tvOS"], 4: ["iOS", "watchOS"], 11: ["visionOS", "xrOS"]]
        return accepted[machOPlatform].map { !$0.isDisjoint(with: platforms) } ?? false
    }

    static func select(from profiles: [ProvisioningProfile], bundleIdentifier: String, certificate: Data) throws -> ProvisioningProfile {
        let candidates = profiles.filter {
            $0.matches(bundleIdentifier: bundleIdentifier) && $0.developerCertificates.contains(certificate)
        }
        .sorted { $0.specificity > $1.specificity }
        guard let best = candidates.first else {
            let authorized = profiles.filter { $0.developerCertificates.contains(certificate) }.map(\.bundleIdentifierPattern).sorted()
            let allowed = Array(Set(authorized)).sorted().prefix(6).joined(separator: ", ")
            throw LoadSideError(
                "profile.noMatch",
                "No profile authorizes \(bundleIdentifier) with the selected certificate. Profile App IDs: \(allowed.isEmpty ? "none for this certificate" : allowed).",
                recovery:
                    "Add a matching profile containing the selected certificate to keep this identifier. To intentionally change the main app’s identity, enter an authorized override or select Automatic bundle ID selection."
            )
        }
        let equal = candidates.filter { $0.specificity == best.specificity && $0.uuid != best.uuid }
        guard equal.isEmpty else {
            throw LoadSideError(
                "profile.ambiguous", "Several profiles match \(bundleIdentifier) equally well.",
                recovery: "Remove the extra matching profiles so each bundle has an unambiguous profile.")
        }
        return best
    }

    private var specificity: Int {
        applicationIdentifier.contains("*") ? applicationIdentifier.count : 10_000 + applicationIdentifier.count
    }

    private static func decodeVerifiedCMS(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw LoadSideError("profile.empty", "The provisioning profile is empty.") }
        var decoder: CMSDecoder?
        try securityCheck(CMSDecoderCreate(&decoder), "create profile decoder")
        guard let decoder else { throw LoadSideError("profile.decoder", "The system could not create a CMS decoder.") }
        try data.withUnsafeBytes { try securityCheck(CMSDecoderUpdateMessage(decoder, $0.baseAddress!, data.count), "read profile CMS") }
        try securityCheck(CMSDecoderFinalizeMessage(decoder), "decode profile CMS")
        var count = 0
        try securityCheck(CMSDecoderGetNumSigners(decoder, &count), "read profile signer")
        guard count == 1 else {
            throw LoadSideError("profile.unsigned", "A provisioning profile must have exactly one trusted Apple CMS signer.")
        }
        var status = CMSSignerStatus.unsigned
        var trust: SecTrust?
        var verify: OSStatus = errSecSuccess
        try securityCheck(
            CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), false, &status, &trust, &verify), "verify profile signature")
        guard status == .valid, let trust else {
            throw LoadSideError("profile.signature", "The provisioning profile’s CMS signature is invalid.")
        }
        // Offline trust is deliberate: no profile or certificate material is sent to a service.
        SecTrustSetNetworkFetchAllowed(trust, false)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else { throw trustEvaluationFailure(error) }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], chain.count == 3, let root = chain.last,
            appleRootFingerprints.contains(SHA256.hash(data: SecCertificateCopyData(root) as Data).hex)
        else {
            throw LoadSideError(
                "profile.trust", "The profile signer does not chain to a trusted Apple root.",
                recovery:
                    "Use an original current Apple-issued mobileprovision. Install current macOS trust updates if a valid profile is rejected."
            )
        }
        // Mirror Apple's published iPhoneProvisioningProfileSigning policy using
        // public APIs: a developer certificate also chains to Apple but is NOT a
        // provisioning-profile signer. The Apple issuer and leaf CN are required.
        var leafName: CFString?
        var issuerName: CFString?
        try securityCheck(SecCertificateCopyCommonName(chain[0], &leafName), "read profile signer name")
        try securityCheck(SecCertificateCopyCommonName(chain[1], &issuerName), "read profile issuer name")
        guard leafName as String? == "Apple iPhone OS Provisioning Profile Signing",
            issuerName as String? == "Apple iPhone Certification Authority"
        else {
            throw LoadSideError(
                "profile.signer", "This Apple certificate is not authorized to sign provisioning profiles.",
                recovery: "Use an unmodified provisioning profile downloaded from Apple Developer.")
        }
        var content: CFData?
        try securityCheck(CMSDecoderCopyContent(decoder, &content), "read profile contents")
        guard let content else { throw LoadSideError("profile.empty", "The profile contains no provisioning payload.") }
        return content as Data
    }

    static func trustEvaluationFailure(_ error: CFError?) -> LoadSideError {
        let code = error.map(CFErrorGetCode)
        let reason = error.map { CFErrorCopyDescription($0) as String } ?? "No trust-service diagnostic was returned."
        // These indicate an unavailable/denied Security service, not evidence
        // that Apple's profile signature or certificate chain is untrusted.
        if code == Int(errSecInternalComponent) || code == Int(errSecNotAvailable) || code == Int(errSecInteractionNotAllowed) {
            return LoadSideError(
                "profile.trustUnavailable", "macOS could not evaluate the profile certificate chain (\(code ?? 0)): \(reason)",
                recovery:
                    "Run LoadSide in a normal macOS session with access to system trust services. A restricted shell or automation sandbox may block Security framework access."
            )
        }
        return LoadSideError(
            "profile.trust", "The profile certificate chain failed macOS trust evaluation: \(reason)",
            recovery:
                "Use a current unmodified Apple-issued provisioning profile, check your Mac’s clock, and install current macOS trust updates."
        )
    }
}

// SHA-256 of DER roots published at https://www.apple.com/certificateauthority/.
// Pinning prevents arbitrary user-added trust roots from authorizing profiles.
let appleRootFingerprints: Set<String> = [
    "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
    "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
    "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"
]

func securityCheck(_ status: OSStatus, _ action: String) throws {
    guard status == errSecSuccess else {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Security error \(status)"
        throw LoadSideError(
            "security.\(status)", "Could not \(action): \(reason)",
            recovery: "Verify the certificate password, profile, and macOS Keychain access, then retry.")
    }
}

extension Digest { var hex: String { map { String(format: "%02x", $0) }.joined() } }
