import CFileKeychain
import CryptoKit
import Foundation
import Security

/// Owns the disposable file keychain passed explicitly to the system codesign tool.
/// CFileKeychain contains the required legacy lifecycle and trusted-application APIs.
final class SigningIdentity {
    let keychain: SecKeychain
    let keychainURL: URL
    let certificate: Data
    let fingerprint: String
    let name: String

    init(p12: URL, password: String, workspace: URL, profiles: [ProvisioningProfile]) throws {
        let size = try p12.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? 0) <= 16 * 1_024 * 1_024 else {
            throw LoadSideError("certificate.size", "The P12 must be a regular file under 16 MB.")
        }
        let keychainURL = workspace.appendingPathComponent("signing.keychain-db")
        var created: SecKeychain?
        // Only a random per-job keychain password is used. Neither password enters argv.
        var random = Data(count: 32)
        let randomStatus = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try securityCheck(randomStatus, "generate private keychain password")
        var secret = Data(random.map { String(format: "%02x", $0) }.joined().utf8)
        random.resetBytes(in: random.startIndex..<random.endIndex)
        defer { secret.resetBytes(in: secret.startIndex..<secret.endIndex) }
        try secret.withUnsafeBytes { bytes in
            try securityCheck(
                LSFileKeychainCreate(keychainURL.path, UInt32(bytes.count), bytes.baseAddress!, &created),
                "create private signing keychain")
        }
        guard let created else { throw LoadSideError("keychain.create", "Could not create a temporary signing keychain.") }
        do {
            try secret.withUnsafeBytes {
                try securityCheck(LSFileKeychainUnlock(created, UInt32($0.count), $0.baseAddress!), "unlock private signing keychain")
            }
            var access: SecAccess?
            try securityCheck(LSFileKeychainCreateSigningAccess(&access), "create signing key access policy")
            guard let access else {
                throw LoadSideError("keychain.access", "Could not create a private signing key access policy.")
            }
            let options: [String: Any] = [
                kSecImportExportPassphrase as String: password,
                kSecImportExportKeychain as String: created,
                kSecImportExportAccess as String: access
            ]
            var items: CFArray?
            try securityCheck(
                SecPKCS12Import(try Data(contentsOf: p12) as CFData, options as CFDictionary, &items), "import the P12 (check its password)"
            )
            let dictionaries = items as? [[String: Any]] ?? []
            var matches: [(SecCertificate, Data)] = []
            for dictionary in dictionaries {
                guard let rawIdentity = dictionary[kSecImportItemIdentity as String] else { continue }
                let identity = rawIdentity as! SecIdentity
                var certificate: SecCertificate?
                try securityCheck(SecIdentityCopyCertificate(identity, &certificate), "read signing certificate")
                guard let certificate else { continue }
                let der = SecCertificateCopyData(certificate) as Data
                if profiles.contains(where: { $0.developerCertificates.contains(der) }) && !matches.contains(where: { $0.1 == der }) {
                    matches.append((certificate, der))
                }
            }
            guard matches.count == 1, let match = matches.first else {
                throw LoadSideError(
                    "certificate.match",
                    matches.isEmpty
                        ? "No identity in this P12 is listed in the supplied profiles."
                        : "This P12 contains multiple identities authorized by the supplied profiles.",
                    recovery: "Export one signing identity with its private key, and provide profiles containing that exact certificate.")
            }
            try Self.validateDates(match.0)
            self.keychain = created
            self.keychainURL = keychainURL
            self.certificate = match.1
            self.fingerprint = Insecure.SHA1.hash(data: match.1).hex
            self.name = SecCertificateCopySubjectSummary(match.0) as String? ?? fingerprint
        } catch {
            LSFileKeychainDelete(created)
            throw error
        }
    }

    deinit { LSFileKeychainDelete(keychain) }

    static func validateDates(_ certificate: SecCertificate, now: Date = Date()) throws {
        guard
            let values = SecCertificateCopyValues(
                certificate, [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any]
        else {
            throw LoadSideError("certificate.validity", "Could not read certificate validity dates.")
        }
        func date(_ oid: CFString) -> Date? {
            let field = values[oid as String] as? [String: Any]
            if let value = field?[kSecPropertyKeyValue as String] as? Date { return value }
            if let value = field?[kSecPropertyKeyValue as String] as? NSNumber {
                return Date(timeIntervalSinceReferenceDate: value.doubleValue)
            }
            return nil
        }
        guard let start = date(kSecOIDX509V1ValidityNotBefore), let end = date(kSecOIDX509V1ValidityNotAfter), start <= now, now < end
        else {
            throw LoadSideError(
                "certificate.expired", "The signing certificate is expired or not yet valid.",
                recovery: "Export a current certificate and its private key, then regenerate the matching profiles.")
        }
    }
}
