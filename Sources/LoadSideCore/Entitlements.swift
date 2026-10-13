import CoreFoundation
import Foundation

struct EntitlementResolution {
    let values: [String: Any]
    let warnings: [String]
}

enum EntitlementResolver {
    /// Profile values authorize requested capabilities; they are not copied wholesale.
    static func resolve(
        requested: [String: Any], profile: ProvisioningProfile, bundleIdentifier: String,
        policy: EntitlementPolicy, useProfileIdentity: Bool = false,
        onWarning: (String) -> Void = { _ in }
    ) throws -> EntitlementResolution {
        if useProfileIdentity {
            // Main/extension eligibility is resolved by the signing plan. Here
            // only an exact identity can be used; wildcard claims are never signed.
            guard !profile.bundleIdentifierPattern.contains("*") else {
                throw LoadSideError(
                    "entitlements.profileIdentity", "Profile identity reuse requires an exact signing application-identifier.")
            }
            try SigningPreflight.validateIdentifier(profile.bundleIdentifierPattern)
        }
        let appID = useProfileIdentity ? profile.applicationIdentifier : "\(profile.appIdentifierPrefix).\(bundleIdentifier)"
        var result = requested
        var warnings: [String] = []
        func warn(_ message: String) {
            warnings.append(message)
            onWarning(message)
        }
        let oldAppID = requested["application-identifier"] as? String
        let oldPrefix = oldAppID.map { String($0.prefix { $0 != "." }) }
        result["application-identifier"] = appID
        result["com.apple.developer.team-identifier"] = profile.teamIdentifier
        if let groups = requested["keychain-access-groups"] as? [String] {
            result["keychain-access-groups"] = groups.map { group in
                if group == oldAppID { return appID }
                if let oldPrefix, group.hasPrefix(oldPrefix + ".") {
                    return profile.appIdentifierPrefix + group.dropFirst(oldPrefix.count)
                }
                return group
            }
        } else if requested.isEmpty, let allowed = profile.entitlements["keychain-access-groups"], isAllowed([appID], by: allowed) {
            result["keychain-access-groups"] = [appID]
        }
        // Never grant debugger access that the source did not request. A false
        // claim can be omitted; distribution must shed an existing true claim.
        if let requestedDebug = result["get-task-allow"] as? Bool {
            if !requestedDebug { result.removeValue(forKey: "get-task-allow") }
            // True is validated by the same strict/compatible rules as every
            // other capability below. No privilege is silently granted/dropped.
        }
        // Report all known approval-required omissions before ordinary strict
        // validation can throw, so failed jobs retain these diagnostics too.
        for key in result.keys.sorted() {
            guard let entry = ApprovalRequiredEntitlements.entry(for: key, profile: profile), let value = result[key] else { continue }
            if profile.entitlements[key].map({ isAuthorized(value, by: $0, entitlement: key) }) == true { continue }
            var detail = ""
            if let restrictedValues = entry.restrictedValues {
                // Shared keys must retain ordinary and already-authorized items.
                // Malformed values continue through normal policy validation.
                guard let values = value as? [String] else { continue }
                let omitted = Set(
                    values.filter { item in
                        restrictedValues.contains(item)
                            && profile.entitlements[key].map({ isAuthorized([item], by: $0, entitlement: key) }) != true
                    })
                guard !omitted.isEmpty else { continue }
                let remaining = values.filter { !omitted.contains($0) }
                if remaining.isEmpty { result.removeValue(forKey: key) } else { result[key] = remaining }
                detail = " values [\(omitted.sorted().joined(separator: ", "))]"
            } else {
                result.removeValue(forKey: key)
            }
            warn(
                "Omitted Apple-approval entitlement \(key)\(detail) (\(entry.name)) from \(bundleIdentifier): profile “\(profile.name)” does not authorize it. This capability is not required to continue signing. Features using it may stop working."
            )
        }
        for key in result.keys.sorted() {
            guard let value = result[key] else { continue }
            let authorized = profile.entitlements[key].map { isAuthorized(value, by: $0, entitlement: key) } ?? false
            if authorized { continue }
            if key == "get-task-allow", value as? Bool == false, profile.entitlements[key] == nil {
                result.removeValue(forKey: key)
                continue
            }
            if policy == .compatible, !["application-identifier", "com.apple.developer.team-identifier"].contains(key) {
                result.removeValue(forKey: key)
                warn("Removed unsupported entitlement \(key) from \(bundleIdentifier). Features using it may stop working.")
            } else {
                throw LoadSideError(
                    "entitlements.unsupported",
                    "Profile “\(profile.name)” does not authorize entitlement “\(key)” requested by \(bundleIdentifier).",
                    recovery: "Use a profile with this capability, or explicitly choose Compatible mode to remove unsupported capabilities."
                )
            }
        }
        return EntitlementResolution(values: result, warnings: warnings)
    }

    static func matches(_ requested: String, allowed: String) -> Bool {
        if !allowed.contains("*") { return requested == allowed }
        guard allowed.hasSuffix("*"), allowed.filter({ $0 == "*" }).count == 1 else { return false }
        return !requested.contains("*") && requested.hasPrefix(String(allowed.dropLast()))
    }

    private static func isAuthorized(_ requested: Any, by allowed: Any, entitlement: String) -> Bool {
        if entitlement == "com.apple.developer.associated-domains" {
            // Apple profiles may encode this capability as the scalar "*", while
            // the signature must retain the app's array of service:domain claims.
            // Domain claims can themselves contain Apple's subdomain wildcard;
            // that syntax must not loosen wildcard rules for identity entitlements.
            guard let domains = requested as? [String], domains.allSatisfy({ !$0.isEmpty && $0 != "*" }) else { return false }
            if allowed as? String == "*" { return true }
            guard let allowlist = allowed as? [String] else { return false }
            if allowlist.contains("*") { return true }
            return domains.allSatisfy { domain in
                allowlist.contains(domain) || allowlist.contains { matches(domain, allowed: $0) }
            }
        }
        return isAllowed(requested, by: allowed)
    }

    static func isAllowed(_ requested: Any, by allowed: Any) -> Bool {
        if let requested = requested as? String, let allowed = allowed as? String { return matches(requested, allowed: allowed) }
        if let requested = requested as? [Any], let allowed = allowed as? [Any] {
            return requested.allSatisfy { item in allowed.contains { isAllowed(item, by: $0) } }
        }
        if let requested = requested as? [String: Any], let allowed = allowed as? [String: Any] {
            return requested.allSatisfy { key, value in allowed[key].map { isAllowed(value, by: $0) } ?? false }
        }
        if let requested = requested as? NSNumber, let allowed = allowed as? NSNumber {
            // A plist boolean and an integer are not interchangeable authorizations.
            guard (CFGetTypeID(requested) == CFBooleanGetTypeID()) == (CFGetTypeID(allowed) == CFBooleanGetTypeID()) else { return false }
            return requested == allowed
        }
        return false
    }
}
